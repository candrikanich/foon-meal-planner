import Foundation

/// A repeating stretch away from home (`members.attendance_defaults.away_pattern`): shared custody, every other weekend.
/// `public.away_pattern_covers` is the same rule on the server, which is what starts each week; this one shows the planner
/// what they've set. Weeks already started don't change.
struct AwayPattern: Codable, Equatable, Hashable, Sendable {
    static let weekend: Set<Int> = [5, 6, 7]

    /// The first of every this many weeks, 2 to 4.
    var everyWeeks: Int
    /// The first night away. Each week is the seven nights from here, so a pattern can change hands midweek. A weekend
    /// counts from its Friday (`firstNight`).
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
        let written = try container.decode(String.self, forKey: .from)
        guard written.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil,
              let day = try? JSONDecoder().decode(CalendarDay.self, from: Data("\"\(written)\"".utf8)), Self.exists(day) else {
            throw DecodingError.dataCorruptedError(forKey: .from, in: container, debugDescription: "Expected a real yyyy-MM-dd")
        }
        from = day
        // Missing is all seven; anything else that isn't weekdays is a bad pattern, as on the server.
        let listed = container.contains(.days) ? try container.decode([Int].self, forKey: .days) : []
        guard listed.allSatisfy((1...7).contains) else {
            throw DecodingError.dataCorruptedError(forKey: .days, in: container, debugDescription: "Expected ISO weekdays")
        }
        days = Set(listed)
    }

    /// Postgres won't take February 31st, so this doesn't either.
    private static func exists(_ day: CalendarDay) -> Bool {
        let leap = day.year % 4 == 0 && (day.year % 100 != 0 || day.year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day.year >= 1 && (1...12).contains(day.month) && (1...lengths[day.month - 1]).contains(day.day)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(everyWeeks, forKey: .everyWeeks)
        try container.encode(from, forKey: .from)
        if !days.isEmpty { try container.encode(days.sorted(), forKey: .days) }
    }

    /// Where the cycle counts from. Seven-night stretches from a Saturday would split the weekend, and give a Friday on the
    /// weekend they're home, so Friday to Sunday counts from that weekend's Friday.
    var firstNight: CalendarDay {
        days == Self.weekend ? from.adding(days: -((from.isoWeekday + 2) % 7)) : from
    }

    /// With the date the editor should show, which is what's saved.
    func snapped() -> AwayPattern {
        AwayPattern(everyWeeks: everyWeeks, from: firstNight, days: days)
    }

    func covers(_ day: CalendarDay) -> Bool {
        let since = day.days(since: firstNight)
        return since >= 0 && since / 7 % everyWeeks == 0 && (days.isEmpty || days.contains(day.isoWeekday))
    }

    /// The next night out from `day` on. A cycle is at most four weeks, so one's always that close.
    func nextNight(onOrAfter day: CalendarDay) -> CalendarDay? {
        (0..<((everyWeeks + 1) * 7)).lazy
            .map { max(day, firstNight).adding(days: $0) }
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
