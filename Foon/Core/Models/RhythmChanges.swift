import Foundation

/// What Family → Rhythm changed, and nothing else. The server merges keys, so a stale phone saving a new dinner time can't
/// put back another planner's week start, or touch keys this screen doesn't own (`onboarded`, `time_zone`, the kitchen's).
struct RhythmChanges: Encodable, Equatable, Sendable {
    var planningDay: Int?
    var planningTime: String?
    var weekStart: Int?
    var dinnerTime: String?
    var newDishesPerWeek: Int?
    var takeoutNights: Int?
    var leftoverNights: Int?
    var repeatWindowDays: Int?
    var notificationPreset: HouseholdSettings.NotificationPreset?
    var checkInTime: String?

    private enum CodingKeys: String, CodingKey {
        case planningDay = "planning_day"
        case planningTime = "planning_time"
        case weekStart = "week_start"
        case dinnerTime = "dinner_time"
        case newDishesPerWeek = "new_dishes_per_week"
        case takeoutNights = "takeout_nights"
        case leftoverNights = "leftover_nights"
        case repeatWindowDays = "repeat_window_days"
        case notificationPreset = "notification_preset"
        case checkInTime = "check_in_time"
    }

    init(from old: HouseholdSettings, to new: HouseholdSettings) {
        func changed<Value: Equatable>(_ key: KeyPath<HouseholdSettings, Value>) -> Value? {
            old[keyPath: key] == new[keyPath: key] ? nil : new[keyPath: key]
        }
        planningDay = changed(\.planningDay)
        planningTime = changed(\.planningTime)
        weekStart = changed(\.weekStart)
        dinnerTime = changed(\.dinnerTime)
        newDishesPerWeek = changed(\.newDishesPerWeek)
        takeoutNights = changed(\.takeoutNights)
        leftoverNights = changed(\.leftoverNights)
        repeatWindowDays = changed(\.repeatWindowDays)
        notificationPreset = changed(\.notificationPreset)
        checkInTime = changed(\.checkInTime)
    }

    var isEmpty: Bool {
        self == RhythmChanges(from: HouseholdSettings(), to: HouseholdSettings())
    }

    /// `settings` as they are now, with only these changes: what's known from the server for everything else.
    func applied(to settings: HouseholdSettings) -> HouseholdSettings {
        var merged = settings
        if let planningDay { merged.planningDay = planningDay }
        if let planningTime { merged.planningTime = planningTime }
        if let weekStart { merged.weekStart = weekStart }
        if let dinnerTime { merged.dinnerTime = dinnerTime }
        if let newDishesPerWeek { merged.newDishesPerWeek = newDishesPerWeek }
        if let takeoutNights { merged.takeoutNights = takeoutNights }
        if let leftoverNights { merged.leftoverNights = leftoverNights }
        if let repeatWindowDays { merged.repeatWindowDays = repeatWindowDays }
        if let notificationPreset { merged.notificationPreset = notificationPreset }
        if let checkInTime { merged.checkInTime = checkInTime }
        return merged
    }
}

/// Whether the week start can change right now. This Week finds a plan by the day it starts, so moving the start while a
/// plan is running would hide its dinners and let a second plan start over the same nights.
enum WeekStartCheck: Equatable, Sendable {
    case free
    /// The last night of the latest plan: the start can move once it's over.
    case lockedThrough(CalendarDay)
    /// Couldn't read the plans, so it stays put.
    case unknown

    static func of(latestWeek: CalendarDay?, today: CalendarDay) -> WeekStartCheck {
        guard let last = latestWeek?.adding(days: 6), last >= today else { return .free }
        return .lockedThrough(last)
    }
}
