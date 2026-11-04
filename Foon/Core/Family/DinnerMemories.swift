import Foundation

/// One logged dinner as the timeline needs it, from `meal_logs` with its night and plan: when, and what was eaten.
/// No cook, reactions or anyone's name (docs/spec.md → Dinner memories: only the food and the night).
struct MemoryLog: Decodable, Equatable, Sendable {
    let nightID: UUID
    let date: CalendarDay
    /// The night's own dinner time, "18:00:00"; nil falls back to the household's.
    let dinnerTime: String?
    let mealName: String?
    let quickPick: QuickPick?
    /// A dish was logged, even if its name couldn't be read.
    let hasMeal: Bool
    /// The night's week was approved: drafts don't count, as on the stats card.
    let approved: Bool

    init(nightID: UUID, date: CalendarDay, dinnerTime: String?, mealName: String?, quickPick: QuickPick?,
         hasMeal: Bool, approved: Bool) {
        self.nightID = nightID
        self.date = date
        self.dinnerTime = dinnerTime
        self.mealName = mealName
        self.quickPick = quickPick
        self.hasMeal = hasMeal
        self.approved = approved
    }

    /// The columns `HouseholdClient.dinnerMemories` reads.
    static let columns = """
        meal_id, quick_pick, meals(name), plan_nights!inner(id, date, dinner_time, plans(approved_at))
        """

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case meal = "meals"
        case night = "plan_nights"
    }

    private struct Night: Decodable {
        struct Plan: Decodable {
            let approvedAt: String?
            enum CodingKeys: String, CodingKey { case approvedAt = "approved_at" }
        }

        let id: UUID
        let date: CalendarDay
        let dinnerTime: String?
        let plans: Plan?

        enum CodingKeys: String, CodingKey {
            case id, date, plans
            case dinnerTime = "dinner_time"
        }
    }

    private struct Meal: Decodable { let name: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let night = try container.decode(Night.self, forKey: .night)
        nightID = night.id
        date = night.date
        dinnerTime = night.dinnerTime
        approved = night.plans?.approvedAt != nil
        mealName = try container.decodeIfPresent(Meal.self, forKey: .meal)?.name
        hasMeal = try container.decodeIfPresent(UUID.self, forKey: .mealID) != nil
        quickPick = try container.decodeIfPresent(QuickPick.self, forKey: .quickPick)
    }
}

/// A logged night eaten at home, titled by its dish or quick pick.
struct MemoryNight: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: CalendarDay
    let dinnerTime: String?
    let title: String
}

/// A photo in this device's library, as little as the timeline needs: PhotoKit's local identifier and when it was
/// taken. PhotoKit's own objects aren't Sendable, so only these cross actors.
struct PhotoStamp: Equatable, Sendable {
    let id: String
    let createdAt: Date
}

/// One night on the timeline and its photos, in the order they were taken.
struct MemoryDinner: Identifiable, Equatable, Sendable {
    let night: MemoryNight
    let photoIDs: [String]

    var id: UUID { night.id }
    var shownPhotoIDs: [String] { Array(photoIDs.prefix(DinnerMemories.shownPhotos)) }
    /// The "+N" after the row.
    var morePhotos: Int { max(0, photoIDs.count - DinnerMemories.shownPhotos) }
}

/// Dinner memories (#65, part 3, docs/spec.md → Dinner memories): photos from this device's library taken around
/// dinner on logged nights. Everything here is pure; the library is read by `PhotoLibrarySource`, and nothing it
/// returns is saved anywhere.
enum DinnerMemories {
    /// A photo counts from half an hour before dinner (the table, the stove) to two hours after. Not a setting.
    static let minutesBefore = 30
    static let minutesAfter = 120
    static let shownPhotos = 6
    /// How far back each page reaches, so the library is never read all at once.
    static let monthsPerPage = 3

    /// Approved nights eaten at home, by the stats card's "at the table" rule: a dish, leftovers, takeout, or a
    /// freezer raid.
    static func nights(from logs: [MemoryLog]) -> [MemoryNight] {
        logs.compactMap { log in
            guard log.approved, let title = title(of: log) else { return nil }
            return MemoryNight(id: log.nightID, date: log.date, dinnerTime: log.dinnerTime, title: title)
        }
    }

    private static func title(of log: MemoryLog) -> String? {
        switch log.quickPick {
        case .leftovers, .takeout, .freezerRaid:
            log.quickPick.map(DayCardText.quickPickLabel)
        case .eatOut, .fendForYourselves:
            nil
        case nil:
            log.hasMeal
                ? log.mealName
                    ?? String(localized: "Dinner", comment: "Dinner memories: a night whose dish has no name")
                : nil
        }
    }

    /// Dinner on the household's clock, from the night's own dinner time or the household's.
    static func dinner(for night: MemoryNight, settings: HouseholdSettings) -> Date? {
        DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date, calendar: settings.dayCalendar)
    }

    /// Clock time is set on the night's own date, so a DST day still has dinner at six; the window is then measured
    /// in real minutes, so a dinner near midnight runs into the next day.
    static func window(for night: MemoryNight, settings: HouseholdSettings) -> DateInterval? {
        guard let dinner = dinner(for: night, settings: settings) else { return nil }
        let start = dinner.addingTimeInterval(-TimeInterval(minutesBefore * 60))
        return DateInterval(start: start, end: dinner.addingTimeInterval(TimeInterval(minutesAfter * 60)))
    }

    static func windows(for nights: [MemoryNight], settings: HouseholdSettings) -> [DateInterval] {
        nights.compactMap { window(for: $0, settings: settings) }
    }

    /// Each photo goes to the night whose window it's in; in two overlapping windows, to the nearer dinner, and
    /// exactly between them to the one already started. Newest night first, and nights without photos are left out.
    static func dinners(nights: [MemoryNight], photos: [PhotoStamp], settings: HouseholdSettings) -> [MemoryDinner] {
        let timed = nights.compactMap { night -> (night: MemoryNight, dinner: Date, window: DateInterval)? in
            guard let dinner = dinner(for: night, settings: settings),
                  let window = window(for: night, settings: settings) else { return nil }
            return (night, dinner, window)
        }
        var seen = Set<String>()
        let unique = photos.filter { seen.insert($0.id).inserted }
        let claimed = Dictionary(grouping: unique.compactMap { photo -> (UUID, PhotoStamp)? in
            let fits = timed.filter { $0.window.contains(photo.createdAt) }
            let nearest = fits.min { lhs, rhs in
                let left = abs(lhs.dinner.timeIntervalSince(photo.createdAt))
                let right = abs(rhs.dinner.timeIntervalSince(photo.createdAt))
                return left == right ? lhs.dinner < rhs.dinner : left < right
            }
            return nearest.map { ($0.night.id, photo) }
        }, by: \.0)
        return timed
            .sorted { $0.dinner > $1.dinner }
            .compactMap { entry in
                guard let photos = claimed[entry.night.id] else { return nil }
                let ids = photos.map(\.1).sorted { $0.createdAt < $1.createdAt }.map(\.id)
                return MemoryDinner(night: entry.night, photoIDs: ids)
            }
    }

    /// Page 0 is the 1st of the month two months back through today; each later page is the three months before.
    static func page(_ index: Int, today: CalendarDay,
                     calendar: Calendar) -> (from: CalendarDay, through: CalendarDay) {
        let thisMonth = CalendarDay(year: today.year, month: today.month, day: 1).date(in: calendar)
        func monthStart(_ back: Int) -> CalendarDay {
            CalendarDay(calendar.date(byAdding: .month, value: -back, to: thisMonth) ?? thisMonth, calendar: calendar)
        }
        let from = monthStart(monthsPerPage * (index + 1) - 1)
        let through = index == 0 ? today : monthStart(monthsPerPage * index - 1).adding(days: -1, calendar: calendar)
        return (from, through)
    }

    /// "Photo from dinner, Friday, October 30": the night, never anyone in it.
    static func photoLabel(for night: MemoryNight, calendar: Calendar, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        style.locale = locale
        let day = night.date.date(in: calendar).formatted(style)
        return String(localized: "Photo from dinner, \(day)",
                      comment: "Dinner memories: VoiceOver label for a photo; the night's weekday and date")
    }

    /// The night's heading: "Friday, October 30", with the year if it isn't this one.
    static func dateLabel(for night: MemoryNight, today: CalendarDay, calendar: Calendar) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        return night.date.date(in: calendar).formatted(night.date.year == today.year ? style : style.year())
    }
}
