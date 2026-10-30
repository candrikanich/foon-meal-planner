import Foundation

/// "Start cooking at 5:45 PM for 6:30 PM dinner" (docs/spec.md → Cooking start time): a dish's time, counted back from
/// that night's dinner. Wall-clock minutes only, so no time zone or daylight saving can move it.
struct StartCooking: Equatable, Sendable {
    /// For dishes that don't say. Tags are all most dishes have, and typing a time for each would add to the planner's
    /// load, so an estimate says "around" and a dish's own time replaces it.
    enum Estimate {
        /// The Quick tag means under 30 minutes.
        static let quick = 30
        /// The same 8 hours as the starter pack's "Start the slow cooker" step.
        static let slowCooker = 8 * 60
        static let usual = 60
    }

    let cookMinutes: Int
    let isEstimate: Bool
    /// Minutes after midnight.
    let startMinute: Int
    let dinnerMinute: Int

    /// Nil on a past night, when the household turned it off, or when dinner's time won't read. Also nil when cooking
    /// would start the day before: a line about what time to start wouldn't say which day.
    static func nudge(for meal: LibraryMeal, on night: WeekNight, settings: HouseholdSettings,
                      today: CalendarDay) -> StartCooking? {
        guard settings.showsStartCooking, night.date >= today,
              let dinner = minuteOfDay(night.dinnerTime ?? settings.dinnerTime) else { return nil }
        let minutes = meal.cookMinutes ?? estimate(for: meal)
        guard dinner >= minutes else { return nil }
        return StartCooking(cookMinutes: minutes, isEstimate: meal.cookMinutes == nil, startMinute: dinner - minutes,
                            dinnerMinute: dinner)
    }

    private static func estimate(for meal: LibraryMeal) -> Int {
        if meal.tags.contains(.slowCooker) { return Estimate.slowCooker }
        return meal.tags.contains(.quick) ? Estimate.quick : Estimate.usual
    }

    /// "HH:mm", with or without the seconds Postgres adds.
    private static func minuteOfDay(_ time: String) -> Int? {
        let parts = time.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, let hour = parts[0], let minute = parts[1] else { return nil }
        return hour * 60 + minute
    }

    func text(locale: Locale = .current) -> String {
        let start = Self.clock(startMinute, locale: locale), dinner = Self.clock(dinnerMinute, locale: locale)
        return isEstimate
            ? String(localized: "Start cooking around \(start) for \(dinner) dinner",
                     comment: "Day card badge from an estimated cooking time: two clock times")
            : String(localized: "Start cooking at \(start) for \(dinner) dinner",
                     comment: "Day card badge from the dish's own cooking time: two clock times")
    }

    private static func clock(_ minute: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(minute * 60))
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).hour().minute())
    }
}
