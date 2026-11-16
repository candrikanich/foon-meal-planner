import Foundation

/// The quiet label on a shopping list row naming the nights, and the dishes on them, that need the item:
/// "Tue · Chili, Fri · Tacos". Pure, so the wording and the weekday math are tested without a view.
struct ListNightLabel: Equatable, Sendable {
    /// What the row shows: short weekdays.
    let text: String
    /// What VoiceOver reads: full weekdays, as a sentence.
    let spoken: String

    /// Nil when there are no nights, so a hand-added line shows nothing. Sorted by night, and the same night and
    /// dish twice (a dish and its side) reads once.
    init?(_ nights: [ListNightRef], locale: Locale = .current, calendar: Calendar = .current) {
        let unique = Set(nights).sorted { ($0.date, $0.mealName ?? "") < ($1.date, $1.mealName ?? "") }
        let parts = unique.compactMap { night -> (short: String, full: String, meal: String?)? in
            guard let date = Self.date(from: night.date, calendar: calendar) else { return nil }
            let style = { (width: Date.FormatStyle.Symbol.Weekday) in
                date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .weekday(width))
            }
            return (style(.abbreviated), style(.wide), night.mealName)
        }
        guard !parts.isEmpty else { return nil }
        let shorts = parts.map { part in
            part.meal.map { String(localized: "\(part.short) · \($0)", locale: locale,
                                   comment: "A list row's label: a short weekday, then the dish planned that night") }
                ?? part.short
        }
        let fulls = parts.map { part in
            part.meal.map { String(localized: "\($0) on \(part.full)", locale: locale,
                                   comment: "Spoken for a list row: the dish, then the weekday it's planned for") }
                ?? part.full
        }
        text = shorts.formatted(.list(type: .and, width: .narrow).locale(locale))
        let nightsSpoken = fulls.formatted(.list(type: .and, width: .standard).locale(locale))
        spoken = String(localized: "Needed for \(nightsSpoken)", locale: locale,
                        comment: "Spoken for a list row: the dishes and nights that need this item")
    }

    /// A plain calendar date, read in the given calendar so no time zone shifts it to the day before.
    private static func date(from iso: String, calendar: Calendar) -> Date? {
        let fields = iso.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2], hour: 12))
    }
}
