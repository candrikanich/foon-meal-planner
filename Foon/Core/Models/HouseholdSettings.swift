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
    /// What the kitchen doesn't have. It lists what's missing rather than what's owned, so a household that hasn't said,
    /// and equipment added to the list later, keep every dish. Like the away dates this isn't encoded with the other
    /// settings, so a stale copy saved with them can't undo another planner's choice: only `kitchen` writes it.
    var missingEquipment: Set<KitchenEquipment> = []
    /// Listed by a newer app. This one can't use them, but its own saves keep them.
    var otherMissingEquipment: [String] = []
    /// Whether cards say when to start cooking. Saved with `kitchen`, like the list.
    var showsStartCooking = true
    /// What the household skips, and when. Read here, but written only through `set_food_rule`, which merges on the server,
    /// so it isn't encoded: a stale copy saved with other settings can't undo another planner's rule.
    var foodRules: [FoodRule] = []
    /// Which dinner jobs the household uses, and who's left out. Read here, but written only through `set_dinner_job` and
    /// `set_dinner_job_person`, so it isn't encoded: a stale copy saved with other settings can't undo a planner's choice.
    var dinnerJobs = DinnerJobSettings()

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

    /// What Family → Kitchen saves: its own keys and nothing else. Always includes the list, since the server merges
    /// keys and leaving out an empty one would keep the old one.
    struct Kitchen: Encodable, Equatable, Sendable {
        let missingEquipment: [String]
        let showsStartCooking: Bool

        private enum CodingKeys: String, CodingKey {
            case missingEquipment = "missing_equipment"
            case showsStartCooking = "start_cooking_nudge"
        }
    }

    var kitchen: Kitchen {
        Kitchen(missingEquipment: KitchenEquipment.allCases.filter(missingEquipment.contains).map(\.rawValue)
                    + otherMissingEquipment,
                showsStartCooking: showsStartCooking)
    }

    /// These settings, with the kitchen's values from `other`.
    func withKitchen(of other: HouseholdSettings) -> HouseholdSettings {
        var merged = self
        merged.missingEquipment = other.missingEquipment
        merged.otherMissingEquipment = other.otherMissingEquipment
        merged.showsStartCooking = other.showsStartCooking
        return merged
    }

    /// These settings, with the food rules from `other`, which is what's known from the server.
    func withFoodRules(of other: HouseholdSettings) -> HouseholdSettings {
        var merged = self
        merged.foodRules = other.foodRules
        return merged
    }

    /// These settings, with the dinner jobs from `other`, which is what's known from the server.
    func withDinnerJobs(of other: HouseholdSettings) -> HouseholdSettings {
        var merged = self
        merged.dinnerJobs = other.dinnerJobs
        return merged
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
        case missingEquipment = "missing_equipment"
        case showsStartCooking = "start_cooking_nudge"
        case foodRules = "food_rules"
        case dinnerJobs = "dinner_jobs"
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
        let missing = ((try? container.decodeIfPresent([String].self, forKey: .missingEquipment)) ?? nil) ?? []
        missingEquipment = Set(missing.compactMap(KitchenEquipment.init(rawValue:)))
        otherMissingEquipment = missing.filter { KitchenEquipment(rawValue: $0) == nil }
        showsStartCooking = (try? container.decodeIfPresent(Bool.self, forKey: .showsStartCooking)).flatMap { $0 } ?? true
        foodRules = ((try? container.decodeIfPresent([FoodRule.Lenient].self, forKey: .foodRules)) ?? nil)?
            .compactMap(\.rule) ?? []
        dinnerJobs = ((try? container.decodeIfPresent(DinnerJobSettings.self, forKey: .dinnerJobs)) ?? nil) ?? DinnerJobSettings()
    }

    /// "HH:mm", or nil for anything else.
    private static func time(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }
            .flatMap { $0.wholeMatch(of: /([01]\d|2[0-3]):[0-5]\d/) != nil ? $0 : nil }
    }
}
