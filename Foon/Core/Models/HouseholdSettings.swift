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
    /// When the planner plans (ISO weekday and "HH:mm"): "Sunday morning, before shopping".
    var planningDay = 7
    var planningTime = "09:00"
    var notificationPreset: NotificationPreset = .balanced
    /// False from creating a household until onboarding finishes; households from before onboarding count as done.
    var onboarded = true
    /// Set by "Load a sample family"; onboarding fills in the demo family, then clears it.
    var samplePending = false
    /// A household made with "Load a sample family": Family offers to delete it and start the real one.
    var isSample = false
    /// The household's time zone (an IANA name), so the server knows when "last night" was. Set when the household
    /// is created; the server falls back to America/New_York without it.
    var timeZone: String?
    /// When the whole household is away. Read here, but written only through `add_away_dates` and `remove_away_dates`,
    /// which merge on the server and bring the weeks already started into line. So they aren't encoded: a stale copy
    /// saved with other settings can't undo them (the server ignores the key anyway, for older apps' sake).
    var awayDates: [AwayDates] = []

    /// Onboarding's presets (docs/spec.md → Notifications): how much Foon nudges.
    enum NotificationPreset: String, Codable, CaseIterable, Sendable {
        case light, balanced, engaged

        var title: String {
            switch self {
            case .light: String(localized: "Light")
            case .balanced: String(localized: "Balanced")
            case .engaged: String(localized: "Engaged")
            }
        }

        /// What each preset sends (docs/spec.md → Notification presets).
        var summary: String {
            switch self {
            case .light:
                String(localized: "Only what you'd hate to miss: time to plan, the plan's set, urgent list items, and prep reminders. No rating prompts or polls.")
            case .balanced:
                String(localized: "Light, plus a \"home tonight?\" check-in and an after-dinner rating prompt. Kids get a few a week at most.")
            case .engaged:
                String(localized: "Everything: idea digests, tonight polls, \"heading to the store,\" the weekly recap, and follow-up reminders.")
            }
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case dinnerTime = "dinner_time"
        case newDishesPerWeek = "new_dishes_per_week"
        case takeoutNights = "takeout_nights"
        case leftoverNights = "leftover_nights"
        case repeatWindowDays = "repeat_window_days"
        case planningDay = "planning_day"
        case planningTime = "planning_time"
        case notificationPreset = "notification_preset"
        case onboarded
        case samplePending = "sample_pending"
        case isSample = "sample"
        case timeZone = "time_zone"
        case awayDates = "away_dates"
    }

    /// One bad entry shouldn't cost the rest.
    private struct LenientAwayDates: Decodable {
        let dates: AwayDates?

        init(from decoder: Decoder) throws {
            dates = try? AwayDates(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weekStart, forKey: .weekStart)
        try container.encode(dinnerTime, forKey: .dinnerTime)
        try container.encode(newDishesPerWeek, forKey: .newDishesPerWeek)
        try container.encode(takeoutNights, forKey: .takeoutNights)
        try container.encode(leftoverNights, forKey: .leftoverNights)
        try container.encode(repeatWindowDays, forKey: .repeatWindowDays)
        try container.encode(planningDay, forKey: .planningDay)
        try container.encode(planningTime, forKey: .planningTime)
        try container.encode(notificationPreset, forKey: .notificationPreset)
        try container.encode(onboarded, forKey: .onboarded)
        try container.encode(samplePending, forKey: .samplePending)
        try container.encode(isSample, forKey: .isSample)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
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
        dinnerTime = Self.time(container, .dinnerTime) ?? defaults.dinnerTime
        planningDay = value(.planningDay, in: 1...7, default: defaults.planningDay)
        planningTime = Self.time(container, .planningTime) ?? defaults.planningTime
        notificationPreset = (try? container.decodeIfPresent(String.self, forKey: .notificationPreset))
            .flatMap { $0 }.flatMap(NotificationPreset.init(rawValue:)) ?? defaults.notificationPreset
        onboarded = (try? container.decodeIfPresent(Bool.self, forKey: .onboarded)).flatMap { $0 } ?? defaults.onboarded
        samplePending = (try? container.decodeIfPresent(Bool.self, forKey: .samplePending)).flatMap { $0 } ?? false
        isSample = (try? container.decodeIfPresent(Bool.self, forKey: .isSample)).flatMap { $0 } ?? false
        timeZone = (try? container.decodeIfPresent(String.self, forKey: .timeZone)).flatMap { $0 }
            .flatMap { TimeZone(identifier: $0)?.identifier }
        awayDates = ((try? container.decodeIfPresent([LenientAwayDates].self, forKey: .awayDates)) ?? nil)?
            .compactMap(\.dates) ?? []
    }

    /// "HH:mm", or nil for anything else.
    private static func time(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }
            .flatMap { $0.wholeMatch(of: /([01]\d|2[0-3]):[0-5]\d/) != nil ? $0 : nil }
    }
}
