import Foundation

/// What a device reminds about on its own (docs/spec.md → Notifications → Delivery: on the device). The raw value is
/// `notification_log.type`. The day-of check-in (#41) joins these: a case, its rule in `NotificationPlanner`, a preset in
/// `ReminderRules`, and a place in `budgetOrder`.
enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case timeToPlan = "time_to_plan"
    case prep = "prep_reminder"
    case afterDinner = "after_dinner"

    /// Who loses out when a week's budget runs short: forgetting to thaw means no dinner, and a rating prompt can wait for
    /// the card on This Week. Nothing about allergies or safety is ever a reminder, so a budget can't drop one.
    var budgetOrder: Int {
        switch self {
        case .timeToPlan: 0
        case .prep: 1
        case .afterDinner: 2
        }
    }
}

/// `members.notification_prefs`, where each person's own settings live. Nothing writes it yet: per-member overrides are
/// #47, and they go here and in `ReminderRules`. Never fails: a value this version can't read means no override.
struct NotificationPrefs: Decodable, Equatable, Sendable {
    var preset: HouseholdSettings.NotificationPreset?

    init(preset: HouseholdSettings.NotificationPreset? = nil) {
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case preset
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        preset = (try? container?.decodeIfPresent(String.self, forKey: .preset))
            .flatMap { $0 }.flatMap(HouseholdSettings.NotificationPreset.init(rawValue:))
    }
}

/// One night, with what reminders need. It lives in the offline cache, so it holds nothing about allergies, and no dish name:
/// nothing on a lock screen uses one.
struct ReminderNight: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: CalendarDay
    var dinnerTime: String?
    var mealID: UUID?
    var quickPick: QuickPick?
    var leftoversFrom: UUID?
    var stashItemID: UUID?
    var prepSteps: [PrepStep] = []
    var attendance: [UUID: Bool] = [:]
    /// Whose rating is in, however it got there: Pass the phone can beat the prompt to it.
    var ratedBy: Set<UUID> = []
    /// The dish someone logged, when they said they had something else.
    var loggedMealID: UUID?

    /// Out of the freezer or left over: already cooked, so nothing to start ahead.
    var isAlreadyCooked: Bool { stashItemID != nil || leftoversFrom != nil }
}

struct ReminderWeek: Codable, Equatable, Sendable {
    let planID: UUID
    let start: CalendarDay
    var isApproved: Bool
    var nights: [ReminderNight]
}

/// This week and next as last read from the server, kept in the offline cache.
struct ReminderSnapshot: Codable, Equatable, Sendable {
    let pulledAt: Date
    let weeks: [ReminderWeek]
}

/// What this device has already done about a reminder.
struct ReminderHistory: Equatable, Sendable {
    let id: String
    var sentAt: Date?
    var respondedAt: Date?
    /// "Remind me in an hour".
    var snoozedUntil: Date?
}

/// Where tapping a notification goes.
enum ReminderRoute: Equatable, Sendable {
    /// This Week, on the week that holds this day.
    case week(CalendarDay)
    case night(UUID, CalendarDay)
    case swap(UUID, CalendarDay)
    /// This Week's after-dinner cards.
    case dinnerCard
}

/// One notification to schedule. Its text is fixed words (`ReminderText`).
struct PlannedReminder: Equatable, Identifiable, Sendable {
    let id: String
    let kind: ReminderKind
    let nightID: UUID?
    let fireAt: Date
    /// A snooze past this is too late to be any use: dinner.
    let dinnerAt: Date?
    let title: String
    let body: String
    let route: ReminderRoute
}

/// Identifiers, all under one prefix so nothing here ever touches a cook-mode timer's (a bare UUID). Each carries the person,
/// so what's left from someone else on this device never matches a plan, and the dish, so one that changed is a different
/// reminder and what was sent for the old dish doesn't count against the new one.
enum ReminderID {
    static let prefix = "foon.reminder."
    private static let followUpSuffix = ".again"

    static func timeToPlan(me: UUID, week: CalendarDay) -> String {
        "\(prefix)\(me.uuidString).plan.\(week.isoString)"
    }

    static func prep(me: UUID, night: UUID, meal: UUID, step: Int) -> String {
        "\(prefix)\(me.uuidString).prep.\(night.uuidString).\(meal.uuidString).\(step)"
    }

    static func afterDinner(me: UUID, night: UUID, meal: UUID) -> String {
        "\(prefix)\(me.uuidString).after.\(night.uuidString).\(meal.uuidString)"
    }

    static func followUp(of id: String) -> String { id + followUpSuffix }

    /// The reminder a follow-up follows.
    static func base(of id: String) -> String {
        id.hasSuffix(followUpSuffix) ? String(id.dropLast(followUpSuffix.count)) : id
    }

    static func isReminder(_ id: String) -> Bool { id.hasPrefix(prefix) }
}
