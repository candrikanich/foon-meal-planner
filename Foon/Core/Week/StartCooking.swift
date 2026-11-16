import Foundation

/// The cook window, "Cook 5:45–6:30 PM" (docs/spec.md → Cooking start time): a dish's time, counted back from
/// that night's dinner. Wall-clock minutes only, so no time zone or daylight saving can move it.
struct StartCooking: Equatable, Sendable {
    /// For the only dishes where a tag or name is a fair guess, and an estimate says "around". Anything else gets no
    /// nudge until someone sets its time: a flat guess is late where it matters, and lasagna would start half an hour late.
    enum Estimate {
        /// The Quick tag means under 30 minutes.
        static let quick = 30
        /// The same 8 hours as the starter pack's "Start the slow cooker" step.
        static let slowCooker = 8 * 60
    }

    let cookMinutes: Int
    let isEstimate: Bool
    /// Minutes after midnight.
    let startMinute: Int
    let dinnerMinute: Int

    /// Nil on a past night, with nobody home, when the household turned it off, when there's no time to go on, or when
    /// dinner's time won't read. Also nil when cooking would start the day before, since a line about what time to start
    /// wouldn't say which day, and tonight once the start has passed (`minuteNow`, on the household's clock): nobody can
    /// follow an instruction for this morning at 3pm.
    static func nudge(for meal: LibraryMeal, on night: WeekNight, settings: HouseholdSettings,
                      today: CalendarDay, minuteNow: Int) -> StartCooking? {
        guard settings.showsStartCooking, night.date >= today,
              night.attendance.isEmpty || night.attendance.values.contains(true),
              let time = minutes(for: meal),
              let dinner = minuteOfDay(night.dinnerTime ?? settings.dinnerTime), dinner >= time.minutes
        else { return nil }
        let start = dinner - time.minutes
        if night.date == today, minuteNow > start { return nil }
        return StartCooking(cookMinutes: time.minutes, isEstimate: time.isEstimate, startMinute: start,
                            dinnerMinute: dinner)
    }

    /// How long a dish takes: its own time, else the estimate from its tags or name. Nil when there's nothing to go on.
    static func minutes(for meal: LibraryMeal) -> (minutes: Int, isEstimate: Bool)? {
        if let own = meal.cookMinutes { return (own, false) }
        return estimate(for: meal).map { ($0, true) }
    }

    private static func estimate(for meal: LibraryMeal) -> Int? {
        if DishTraits(name: meal.name, tags: meal.tags).equipment.contains(.slowCooker) { return Estimate.slowCooker }
        return meal.tags.contains(.quick) ? Estimate.quick : nil
    }

    /// "HH:mm", with or without the seconds Postgres adds.
    private static func minuteOfDay(_ time: String) -> Int? {
        let parts = time.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, let hour = parts[0], let minute = parts[1] else { return nil }
        return hour * 60 + minute
    }

    /// "3:00–6:00 PM", in the locale's own 12 or 24-hour style.
    func range(locale: Locale) -> String {
        let calendar = Self.clockCalendar
        let start = Self.date(startMinute), end = Self.date(dinnerMinute)
        return (start..<end).formatted(Date.IntervalFormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                                calendar: calendar, timeZone: .gmt))
    }

    func clock(_ minute: Int, locale: Locale) -> String {
        Self.date(minute).formatted(Date.FormatStyle(locale: locale, calendar: Self.clockCalendar, timeZone: .gmt)
            .hour().minute())
    }

    private static var clockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static func date(_ minute: Int) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(minute * 60)) }
}
