import Foundation

/// Household rhythm and planning mix (`households.settings`, docs/spec.md → Household planning settings).
/// Every key is optional in the database; anything missing or out of range uses the default here.
struct HouseholdSettings: Equatable, Sendable, Codable {
    /// ISO weekday (1 = Monday … 7 = Sunday) the week starts on: the shopping day.
    var weekStart = 7
    /// "HH:mm", the usual dinner time each night starts with.
    var dinnerTime = "18:00"
    var newDishesPerWeek = 1
    var takeoutNights = 0
    var leftoverNights = 1
    /// Days before a meal can come back around.
    var repeatWindowDays = 10

    init() {}

    private enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case dinnerTime = "dinner_time"
        case newDishesPerWeek = "new_dishes_per_week"
        case takeoutNights = "takeout_nights"
        case leftoverNights = "leftover_nights"
        case repeatWindowDays = "repeat_window_days"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HouseholdSettings()
        func value(_ key: CodingKeys, in range: ClosedRange<Int>, default fallback: Int) -> Int {
            (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 }.flatMap { range.contains($0) ? $0 : nil }
                ?? fallback
        }
        weekStart = value(.weekStart, in: 1...7, default: defaults.weekStart)
        newDishesPerWeek = value(.newDishesPerWeek, in: 0...7, default: defaults.newDishesPerWeek)
        takeoutNights = value(.takeoutNights, in: 0...7, default: defaults.takeoutNights)
        leftoverNights = value(.leftoverNights, in: 0...7, default: defaults.leftoverNights)
        repeatWindowDays = value(.repeatWindowDays, in: 0...60, default: defaults.repeatWindowDays)
        let time = (try? container.decodeIfPresent(String.self, forKey: .dinnerTime)).flatMap { $0 }
        dinnerTime = time.flatMap { $0.wholeMatch(of: /([01]\d|2[0-3]):[0-5]\d/) != nil ? $0 : nil } ?? defaults.dinnerTime
    }
}
