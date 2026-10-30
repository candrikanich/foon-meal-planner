import Foundation

/// One night's pick changing (`plan_changes`), written by a trigger on the server whoever made the write. Anyone in the
/// family reads these; only planners undo one.
struct PlanChange: Identifiable, Equatable, Sendable {
    /// Text on the server, so an entry this build doesn't know decodes with no kind, and isn't shown.
    enum Kind: String, Sendable {
        case pick, doubled, freezer, away, follow, undo
        case undoDouble = "undo_double"
    }

    struct Held: Equatable, Sendable {
        var mealID: UUID?
        var mealName: String?
        var quickPick: QuickPick?
    }

    let id: Int64
    let nightID: UUID
    let nightDate: CalendarDay
    /// Nil when the system moved the night, or the write had no profile behind it.
    let actorID: UUID?
    let kind: Kind?
    /// For Double it and what follows from it: the night cooking twice as much.
    var linkedDate: CalendarDay?
    var before = Held()
    var after = Held()
    let afterLocked: Bool
    /// A plain change with no link on the night when it was made.
    let restorable: Bool
    /// The statement it came from, so a whole Build shares one.
    let createdAt: Date
}

extension PlanChange: Decodable {
    private struct Meal: Decodable { let name: String }
    private struct Night: Decodable { let date: CalendarDay }

    /// The columns to select, with the dish names and the night's date.
    static let columns = """
        id, night_id, actor_member_id, kind, linked_date, before_meal_id, before_quick_pick, after_meal_id, after_quick_pick, \
        after_locked, restorable, created_at, plan_nights(date), \
        before_meal:meals!plan_changes_before_meal_fkey(name), after_meal:meals!plan_changes_after_meal_fkey(name)
        """

    private enum CodingKeys: String, CodingKey {
        case id, kind, restorable
        case nightID = "night_id"
        case actorID = "actor_member_id"
        case linkedDate = "linked_date"
        case beforeMealID = "before_meal_id"
        case beforeQuickPick = "before_quick_pick"
        case afterMealID = "after_meal_id"
        case afterQuickPick = "after_quick_pick"
        case afterLocked = "after_locked"
        case createdAt = "created_at"
        case night = "plan_nights"
        case beforeMeal = "before_meal"
        case afterMeal = "after_meal"
    }

    init(from decoder: any Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        id = try row.decode(Int64.self, forKey: .id)
        nightID = try row.decode(UUID.self, forKey: .nightID)
        nightDate = try row.decode(Night.self, forKey: .night).date
        actorID = try row.decodeIfPresent(UUID.self, forKey: .actorID)
        kind = try Kind(rawValue: row.decode(String.self, forKey: .kind))
        linkedDate = try row.decodeIfPresent(CalendarDay.self, forKey: .linkedDate)
        before = Held(mealID: try row.decodeIfPresent(UUID.self, forKey: .beforeMealID),
                      mealName: try row.decodeIfPresent(Meal.self, forKey: .beforeMeal)?.name,
                      quickPick: try row.decodeIfPresent(QuickPick.self, forKey: .beforeQuickPick))
        after = Held(mealID: try row.decodeIfPresent(UUID.self, forKey: .afterMealID),
                     mealName: try row.decodeIfPresent(Meal.self, forKey: .afterMeal)?.name,
                     quickPick: try row.decodeIfPresent(QuickPick.self, forKey: .afterQuickPick))
        afterLocked = try row.decode(Bool.self, forKey: .afterLocked)
        restorable = try row.decode(Bool.self, forKey: .restorable)
        createdAt = try row.decode(Date.self, forKey: .createdAt)
    }
}

/// What the activity list and a night's detail show, worked out from the rows.
enum PlanActivity {
    /// As many rows as a device reads. The server keeps eight weeks, and a busy family stays well under this.
    static let fetchLimit = 300

    /// A line in the activity view: one change, or everything a Build wrote at once.
    struct Entry: Identifiable, Equatable, Sendable {
        var changes: [PlanChange]
        var id: Int64 { changes[0].id }
    }

    /// Newest first, as read. Nights a single statement planned together are one entry, wherever the system's own moves fall
    /// among them. At the fetch limit the oldest statement may be cut short, and a count of part of a Build would be false,
    /// so it's left off.
    static func entries(_ changes: [PlanChange], limit: Int = fetchLimit) -> [Entry] {
        var known = changes.filter { $0.kind != nil }
        if changes.count >= limit, let oldest = changes.last?.createdAt {
            known.removeAll { $0.createdAt == oldest }
        }
        var entries: [Entry] = []
        for change in known {
            if change.kind == .pick, let index = entries.firstIndex(where: {
                $0.changes[0].kind == .pick && $0.changes[0].createdAt == change.createdAt
                    && $0.changes[0].actorID == change.actorID
            }) {
                entries[index].changes.append(change)
            } else {
                entries.append(Entry(changes: [change]))
            }
        }
        return entries
    }

    /// One night's changes, newest first, leaving out kinds this build doesn't know.
    static func changes(on nightID: UUID, in changes: [PlanChange]) -> [PlanChange] {
        changes.filter { $0.nightID == nightID && $0.kind != nil }
    }

    /// Whether to offer Undo on a night's newest change: the server asks all of this again under a lock. Only if the night
    /// still holds what it says, and never around a link, a logged dinner, away dates, or a dish that's left rotation.
    static func canUndo(_ change: PlanChange, on night: WeekNight, nights: [WeekNight], isLogged: Bool, away: [AwayDates],
                        today: CalendarDay, library: [LibraryMeal]) -> Bool {
        change.kind == .pick && change.restorable
            && change.after.mealID == night.mealID && change.after.quickPick == night.quickPick
            && change.afterLocked == night.locked
            && night.date >= today && !isLogged
            && night.leftoversFrom == nil && night.stashItemID == nil
            && !nights.contains { $0.leftoversFrom == night.id }
            && !away.contains { $0.contains(night.date) }
            && (change.before.mealID.map { id in library.contains { $0.id == id && $0.status.isInRotation } } ?? true)
    }
}

/// The plain-language lines. Food and first names, and Foon when Foon did it.
enum PlanChangeText {
    /// "Dad", or "Former member" for someone removed, as elsewhere. The log's foreign key says they existed, so someone
    /// missing from a loaded family has been removed too. "Someone" with no family loaded, or no profile behind the write.
    private static func who(_ actorID: UUID?, members: [Member]) -> String {
        guard let actorID, !members.isEmpty else { return String(localized: "Someone") }
        guard let member = members.first(where: { $0.id == actorID }), member.status != .removed else {
            return String(localized: "Former member")
        }
        return member.firstName
    }

    /// "Tuesday" for the week ahead, and with the date for a night further off or gone by, since a week of entries can name
    /// two Tuesdays.
    static func day(_ date: CalendarDay, today: CalendarDay, calendar: Calendar) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
        let shown = date.date(in: calendar)
        guard date >= today, date < today.adding(days: 7, calendar: calendar) else {
            return shown.formatted(style.month(.abbreviated).day())
        }
        return shown.formatted(style)
    }

    private static func held(_ held: PlanChange.Held) -> String? {
        held.mealName ?? held.quickPick.map(DayCardText.quickPickLabel)
    }

    static func line(_ entry: PlanActivity.Entry, members: [Member], today: CalendarDay, calendar: Calendar) -> String {
        guard entry.changes.count > 1 else {
            return line(entry.changes[0], members: members, today: today, calendar: calendar)
        }
        let name = who(entry.changes[0].actorID, members: members)
        return String(localized: "\(name) planned \(entry.changes.count) nights",
                      comment: "Activity: a whole Build or Fill. The person's first name, then how many nights")
    }

    static func line(_ change: PlanChange, members: [Member], today: CalendarDay, calendar: Calendar) -> String {
        let name = who(change.actorID, members: members)
        let night = day(change.nightDate, today: today, calendar: calendar)
        let after = held(change.after)
        let linked = change.linkedDate.map { day($0, today: today, calendar: calendar) }
        switch change.kind {
        case .doubled:
            guard let linked else { return String(localized: "\(name) planned leftovers on \(night)") }
            return String(localized: "\(name) doubled \(linked)'s dinner, with leftovers on \(night)",
                          comment: "Activity: the person, the night cooking twice as much, the leftovers night")
        case .undoDouble:
            return String(localized: "\(name) undid Double it on \(night)")
        case .freezer:
            guard let after else { return String(localized: "\(name) planned \(night) from the freezer") }
            return String(localized: "\(name) put \(after) from the freezer on \(night)",
                          comment: "Activity: the person, the dish, the night")
        case .away:
            return String(localized: "Foon cleared \(night) for away dates")
        case .follow:
            guard let linked else {
                return after.map { String(localized: "Foon put \(night) back to \($0)") } ?? String(localized: "Foon cleared \(night)")
            }
            guard let after else { return String(localized: "Foon cleared \(night) when \(linked)'s dinner changed") }
            return String(localized: "Foon put \(night) back to \(after) when \(linked)'s dinner changed",
                          comment: "Activity: a leftovers night going back. The night, what it holds now, the doubled night")
        case .undo:
            guard let after else { return String(localized: "\(name) undid the last change to \(night), so it's empty again") }
            return String(localized: "\(name) undid the last change to \(night), back to \(after)",
                          comment: "Activity: the person, the night, what it holds now")
        case .pick, nil:
            guard let after else { return String(localized: "\(name) cleared \(night)") }
            guard held(change.before) != nil else {
                return String(localized: "\(name) planned \(after) on \(night)",
                              comment: "Activity: the person, the dish, the night")
            }
            return String(localized: "\(name) swapped \(night) to \(after)",
                          comment: "Activity: the person, the night, what it holds now, as in Dad swapped Tuesday to Tacos")
        }
    }

    /// The button on a night's detail.
    static func undoTitle(_ change: PlanChange) -> String {
        guard let before = held(change.before) else { return String(localized: "Undo: leave it empty") }
        return String(localized: "Undo: back to \(before)", comment: "Button on a night's detail, with the dish it held before")
    }
}
