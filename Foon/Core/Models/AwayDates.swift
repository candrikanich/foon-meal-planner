import Foundation

/// A stretch the whole household is away (`households.settings.away_dates`), both nights included: no dinners planned,
/// nothing built for the list, and no notifications about those nights.
struct AwayDates: Codable, Hashable, Identifiable, Sendable {
    let from: CalendarDay
    let to: CalendarDay

    var id: CalendarDay { from }

    init(from: CalendarDay, to: CalendarDay) {
        self.from = from
        self.to = to
    }

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(CalendarDay.self, forKey: .from)
        to = try container.decode(CalendarDay.self, forKey: .to)
        guard from <= to else {
            throw DecodingError.dataCorruptedError(forKey: .to, in: container, debugDescription: "Ends before it starts")
        }
    }

    func contains(_ day: CalendarDay) -> Bool {
        from <= day && day <= to
    }

    /// "Dec 20 to Dec 27", or just "Dec 20"; a date outside this year shows its year.
    func summary(today: CalendarDay) -> String {
        let first = DayCardText.dateLabel(for: from, relativeTo: today)
        guard from != to else { return first }
        let last = DayCardText.dateLabel(for: to, relativeTo: today)
        return String(localized: "\(first) to \(last)", comment: "Away dates: two short dates")
    }

    /// The most the server takes from a first night to a last.
    static let longestSpanDays = 366

    /// The last night to offer once the first has moved: never before it, or further than the server takes.
    static func clampedLast(_ last: CalendarDay, first: CalendarDay) -> CalendarDay {
        max(first, min(last, first.adding(days: longestSpanDays)))
    }

    /// What marking these nights does: how many there are, what comes off them, and that tonight's dinner stays.
    /// `week` is whichever week is loaded; others are covered by the general wording.
    func confirmation(today: CalendarDay, week: [WeekNight]) -> String {
        let count = to.days(since: from) + 1
        let nights = count == 1 ? String(localized: "1 night.") : String(localized: "\(count) nights.")
        let coming = week.filter { contains($0.date) && $0.date > today && $0.isPlanned }.map(PlanIt.currentPick)
        let off = coming.isEmpty
            ? String(localized: "Anything planned for those nights comes off, locked nights included, and doesn't come back if you change your mind.")
            : String(localized: "\(coming.formatted(.list(type: .and))) and anything else planned for those nights come off, locked nights included, and don't come back if you change your mind.")
        let tonight = contains(today)
            ? [String(localized: "Tonight's dinner stays, in case you've eaten it. Swap it off if you won't be home.")] : []
        let list = String(localized: "The shopping list keeps what's already on it until someone taps Update the list on This Week.")
        return ([nights, off] + tonight + [list]).joined(separator: " ")
    }
}

extension WeekNight {
    /// Inside the away dates, and not a dinner that already happened or is happening tonight: marking dates at 9pm
    /// doesn't erase what was eaten, so that night still reads as itself.
    func readsAway(in dates: [AwayDates], today: CalendarDay) -> Bool {
        dates.contains { $0.contains(date) } && !(date <= today && isPlanned)
    }
}

extension HouseholdSettings {
    /// The calendar "today" comes from: the household's time zone, which is what the server goes by too. Without one
    /// (an older household, until a planner's device saves it) it's the device's day, not the server's New York fallback:
    /// that would show tomorrow as tonight during the evening out west.
    var dayCalendar: Calendar {
        timeZone == nil ? .current : DinnerPrompts.calendar(for: self)
    }

    /// Minutes after midnight on the household's clock.
    func minuteOfDay(now: Date = .now) -> Int {
        let time = dayCalendar.dateComponents([.hour, .minute], from: now)
        return (time.hour ?? 0) * 60 + (time.minute ?? 0)
    }

    func today(now: Date = .now) -> CalendarDay {
        CalendarDay(now, calendar: dayCalendar)
    }

    func isAway(on day: CalendarDay) -> Bool {
        awayDates.contains { $0.contains(day) }
    }

    /// The stretches not over yet: ended ones stay stored until the next change, but there's nothing left to show.
    func awayDates(endingOnOrAfter today: CalendarDay) -> [AwayDates] {
        awayDates.filter { $0.to >= today }
    }

    /// The stretches touching the week starting on `start`.
    func awayDates(inWeekOf start: CalendarDay) -> [AwayDates] {
        let end = start.adding(days: 6)
        return awayDates.filter { $0.from <= end && $0.to >= start }
    }
}
