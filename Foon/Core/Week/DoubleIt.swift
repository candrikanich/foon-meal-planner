import Foundation

/// Double it (docs/spec.md → Cook once, eat twice): cook twice as much one night and plan the leftovers on a later night
/// this week. What's doubled is never stored: a night is doubled because a leftovers night points at it (`leftoversFrom`),
/// and the list is rebuilt from that each time, so a scale can't compound and undoing it can't leave a stale amount.
enum DoubleIt {
    /// The nights the weekly list is built from, each saying whether it's doubled or already in the freezer. A doubled
    /// dish is also eaten on its leftovers night, so whoever's home then counts for its allergy notes. Tonight leaves once
    /// its dinner is logged (`logged`): it's over, and what was eaten may not be what was planned.
    static func listNights(_ layout: WeekLayout, logged: Set<UUID> = []) -> [WeeklyList.Night] {
        layout.plannable.filter { !logged.contains($0.id) }.map { night in
            let later = leftoversNight(of: night, in: layout.ahead)
            return WeeklyList.Night(mealID: night.mealID, home: home(night).union(later.map(home) ?? []),
                                    doubled: later != nil, fromFreezer: night.stashItemID != nil)
        }
    }

    private static func home(_ night: WeekNight) -> Set<UUID> {
        Set(night.attendance.filter(\.value).keys)
    }

    /// What changing this night also changes, said before it happens: in Swap, and in Plan it. Shuffle isn't offered on
    /// these nights, since it has nowhere to say it.
    static func changeWarning(for night: WeekNight, in nights: [WeekNight]) -> String? {
        if leftoversNight(of: night, in: nights) != nil {
            return String(localized: "This dish is doubled. Changing it takes its leftovers night back to what it held.")
        }
        if night.leftoversFrom != nil {
            return String(localized: "These are planned leftovers. Changing this night means the dish goes back to its regular amounts when you update the list.")
        }
        if night.stashItemID != nil {
            return String(localized: "This dish is from the freezer. Changing it puts it back in the freezer.")
        }
        return nil
    }

    static func leftoversNight(of night: WeekNight, in nights: [WeekNight]) -> WeekNight? {
        nights.first { $0.leftoversFrom == night.id }
    }

    /// A dish tonight or later, not already doubled, and not out of the freezer (it's already cooked).
    static func canDouble(_ night: WeekNight, in layout: WeekLayout) -> Bool {
        night.mealID != nil && night.stashItemID == nil && layout.ahead.contains { $0.id == night.id }
            && leftoversNight(of: night, in: layout.ahead) == nil
    }

    /// Later nights this week that can take the leftovers, soonest first. A locked night keeps what the planner chose,
    /// unless that's already leftovers. The server has the same rules, plus that the device saw what it's replacing; only
    /// nobody being home is left to here, since an empty table isn't wrong, just not worth offering.
    static func choices(for night: WeekNight, in layout: WeekLayout) -> [WeekNight] {
        layout.plannable.filter { later in
            later.date > night.date && later.effort != .event && later.leftoversFrom == nil && later.stashItemID == nil
                && (!later.locked || later.quickPick == .leftovers)
                && leftoversNight(of: later, in: layout.ahead) == nil
                && (later.attendance.isEmpty || later.attendance.values.contains(true))
        }
    }

    /// The dish a leftovers night is eating, for its allergy flags: the night it's linked to, or a big batch the night
    /// before, which is where Build my week puts them. Unknown otherwise; nothing's flagged that can't be named.
    static func leftoversDish(on night: WeekNight, nights: [WeekNight], library: [LibraryMeal]) -> LibraryMeal? {
        guard night.quickPick == .leftovers else { return nil }
        let meal = { (id: UUID?) in id.flatMap { id in library.first { $0.id == id } } }
        if let source = nights.first(where: { $0.id == night.leftoversFrom }) { return meal(source.mealID) }
        let before = nights.first { night.date.days(since: $0.date) == 1 }
        return meal(before?.mealID).flatMap { $0.tags.contains(.leftovers) ? $0 : nil }
    }

    /// "From Monday's Chili". Always the weekday: "From Tonight's Chili" reads as the wrong night once it's tomorrow.
    static func leftoversNote(from source: WeekNight, calendar: Calendar = .current) -> String? {
        guard let name = source.mealName else { return nil }
        return String(localized: "From \(weekday(source.date, calendar: calendar))'s \(name)",
                      comment: "Day card, on a leftovers night: the weekday and dish they're from")
    }

    /// "Doubled: leftovers Tuesday".
    static func doubledText(leftoversOn night: WeekNight, today: CalendarDay, calendar: Calendar = .current) -> String {
        String(localized: "Doubled: leftovers \(DayCardText.dayLabel(for: night.date, today: today, calendar: calendar))",
               comment: "Day card badge: this dish is cooked twice over, with leftovers on that night")
    }

    /// What Double it does to the list, said before it's done. An approved week's list waits for Update the list, like
    /// every other change to a night; what's bought is never listed again, so an extra has to be added by hand.
    static func listNote(approved: Bool) -> String {
        let doubles = String(localized: "The list gets twice this dish's amounts. Anything marked in stock stays off it, and a line someone added by hand or another approved week wrote keeps its own amount, so check you have enough.")
        guard approved else { return doubles }
        let update = String(localized: "Update the list on This Week to see it. Foon won't list something you've already bought again, so add any extra yourself.")
        return doubles + " " + update
    }

    private static func weekday(_ day: CalendarDay, calendar: Calendar) -> String {
        day.date(in: calendar).formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))
    }
}

/// What `double_it` is told the device saw on both nights.
struct DoubleItRequest: Equatable, Sendable, Encodable {
    let nightID: UUID
    let leftoversNightID: UUID
    let expectedMeal: UUID?
    let expectedLeftoversMeal: UUID?
    let expectedLeftoversPick: QuickPick?

    enum CodingKeys: String, CodingKey {
        case nightID = "target_night"
        case leftoversNightID = "leftovers_night"
        case expectedMeal = "expected_meal"
        case expectedLeftoversMeal = "expected_leftovers_meal"
        case expectedLeftoversPick = "expected_leftovers_pick"
    }

    /// Every argument sent, nulls included: PostgREST matches functions by argument names.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nightID, forKey: .nightID)
        try container.encode(leftoversNightID, forKey: .leftoversNightID)
        try container.encode(expectedMeal, forKey: .expectedMeal)
        try container.encode(expectedLeftoversMeal, forKey: .expectedLeftoversMeal)
        try container.encode(expectedLeftoversPick, forKey: .expectedLeftoversPick)
    }
}
