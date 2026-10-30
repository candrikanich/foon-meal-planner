import Foundation

/// A repeating stretch away from home (`members.attendance_defaults.away_pattern`): shared custody, every other weekend.
/// `public.away_pattern_covers` is the same rule on the server, which is what starts each week; this one shows the planner
/// what they've set. Weeks already started don't change.
struct AwayPattern: Codable, Equatable, Hashable, Sendable {
    static let weekend: Set<Int> = [5, 6, 7]

    /// The first of every this many weeks, 2 to 4.
    var everyWeeks: Int
    /// The first night away. Each week is the seven nights from here, so a pattern can change hands midweek.
    var from: CalendarDay
    /// ISO weekdays out, in those weeks. Empty is all seven.
    var days: Set<Int>

    init(everyWeeks: Int = 2, from: CalendarDay, days: Set<Int> = []) {
        (self.everyWeeks, self.from, self.days) = (everyWeeks, from, days)
    }

    private enum CodingKeys: String, CodingKey {
        case from, days
        case everyWeeks = "every_weeks"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        everyWeeks = try container.decode(Int.self, forKey: .everyWeeks)
        guard (2...4).contains(everyWeeks) else {
            throw DecodingError.dataCorruptedError(forKey: .everyWeeks, in: container, debugDescription: "Expected 2 to 4")
        }
        from = try container.decode(CalendarDay.self, forKey: .from)
        let listed = (try? container.decodeIfPresent([Int].self, forKey: .days)) ?? nil
        days = Set(listed ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(everyWeeks, forKey: .everyWeeks)
        try container.encode(from, forKey: .from)
        if !days.isEmpty { try container.encode(days.sorted(), forKey: .days) }
    }

    func covers(_ day: CalendarDay) -> Bool {
        let since = day.days(since: from)
        return since >= 0 && since / 7 % everyWeeks == 0 && (days.isEmpty || days.contains(day.isoWeekday))
    }

    /// The next night out from `day` on. A cycle is at most four weeks, so one's always that close.
    func nextNight(onOrAfter day: CalendarDay) -> CalendarDay? {
        (0..<((everyWeeks + 1) * 7)).lazy
            .map { max(day, from).adding(days: $0) }
            .first(where: covers)
    }

    static func everyWeeksTitle(_ weeks: Int) -> String {
        weeks == 2 ? String(localized: "Every other week", comment: "How often someone's away")
            : String(localized: "Every \(weeks) weeks", comment: "How often someone's away")
    }

    /// "Every other week" or "Every other weekend".
    var summary: String {
        guard days == Self.weekend else { return Self.everyWeeksTitle(everyWeeks) }
        return everyWeeks == 2 ? String(localized: "Every other weekend", comment: "How often someone's away")
            : String(localized: "Every \(everyWeeks) weeks, Friday to Sunday", comment: "How often someone's away")
    }
}
