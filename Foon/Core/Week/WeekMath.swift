import Foundation

/// Week arithmetic on calendar days. Weekdays are ISO (1 = Monday … 7 = Sunday), as Postgres `isodow` counts.
enum WeekMath {
    struct Weekday: Identifiable, Equatable, Sendable {
        let iso: Int
        var id: Int { iso }

        /// "Mon", in the reader's language. Calendar's weekday symbols always start on Sunday.
        func shortName(calendar: Calendar = .current) -> String {
            calendar.shortWeekdaySymbols[iso % 7]
        }

        /// "Monday", for VoiceOver.
        func name(calendar: Calendar = .current) -> String {
            calendar.weekdaySymbols[iso % 7]
        }
    }

    static let weekdays = (1...7).map(Weekday.init)

    static func isoWeekday(of day: CalendarDay, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: day.date(in: calendar)) // 1 = Sunday
        return weekday == 1 ? 7 : weekday - 1
    }

    /// The week containing `day` starts on the most recent `weekStart` weekday, `day` included.
    static func start(of day: CalendarDay, weekStart: Int, calendar: Calendar = .current) -> CalendarDay {
        let back = (isoWeekday(of: day, calendar: calendar) - weekStart + 7) % 7
        return day.adding(days: -back, calendar: calendar)
    }
}
