import Foundation

/// What a device reminds about on its own (docs/spec.md → Notifications → Delivery: on the device). The raw value is
/// `notification_log.type`.
enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case timeToPlan = "time_to_plan"
    case prep = "prep_reminder"
    case afterDinner = "after_dinner"
    case checkIn = "day_of_check_in"
    /// Rating, once a week, for someone who stopped answering each night (RatingCadence).
    case ratingRoundup = "rating_roundup"

    /// Who loses out when a week's budget runs short: forgetting to thaw means no dinner, and a check-in or a rating prompt
    /// can wait for its card on This Week. Those two share a place, so each night gets both while the budget lasts rather than
    /// one kind using it all up. The weekly roundup sits between: it's one a week standing in for seven prompts, and at the
    /// week's end it would otherwise lose to every check-in before it, but it still waits behind a thaw. Nothing about
    /// allergies or safety is ever a reminder, so a budget can't drop one.
    var budgetOrder: Int {
        switch self {
        case .timeToPlan: 0
        case .prep: 1
        case .ratingRoundup: 2
        case .afterDinner, .checkIn: 3
        }
    }
}

/// `members.notification_prefs`, where each person's own settings live: their own preset, set through
/// `set_member_preset` (MemberPresetRules), read here by `ReminderRules` and on the server by `member_preset`. Never fails:
/// a value this version can't read means no override.
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

/// The kinds of prep step the starter pack has. The step's words only choose one, and then they're dropped.
enum PrepKind: String, Codable, Sendable {
    case thaw, marinate, slowCooker, other

    static let marinateWords = ["marinat", "marinad"]
    static let slowCookerWords = ["slow cooker", "slow-cooker", "crock"]

    init(step: String) {
        let text = step.lowercased()
        if ["thaw", "defrost"].contains(where: text.contains) {
            self = .thaw
        } else if Self.marinateWords.contains(where: text.contains) {
            self = .marinate
        } else if Self.slowCookerWords.contains(where: text.contains) {
            self = .slowCooker
        } else {
            self = .other
        }
    }
}

/// A prep step as reminders keep it: what kind, and how long before dinner. None of what the family typed, so it can't reach
/// the offline cache or a lock screen. Nil for a step with no lead time, which has nothing to count back from.
struct ReminderPrep: Codable, Equatable, Sendable {
    let kind: PrepKind
    let leadHours: Int

    init?(_ step: PrepStep) {
        guard let lead = step.leadHours, lead > 0 else { return nil }
        kind = PrepKind(step: step.step)
        leadHours = lead
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
    var prepSteps: [ReminderPrep] = []
    var attendance: [UUID: Bool] = [:]
    /// Who's already answered this night's check-in, on any phone.
    var checkedIn: Set<UUID> = []
    /// Whose rating is in, however it got there: Pass the phone can beat the prompt to it.
    var ratedBy: Set<UUID> = []
    /// Whether anyone's logged this night, and the dish if it was one: a quick pick logs no dish.
    var hasLog = false
    var loggedMealID: UUID?

    /// Out of the freezer or left over: already cooked, so nothing to start ahead.
    var isAlreadyCooked: Bool { stashItemID != nil || leftoversFrom != nil }
}

extension ReminderNight {
    /// By hand for `checkedIn` alone: a snapshot cached before it existed has to keep reading, or an offline launch after an
    /// update would call off every pending reminder.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(CalendarDay.self, forKey: .date)
        dinnerTime = try container.decodeIfPresent(String.self, forKey: .dinnerTime)
        mealID = try container.decodeIfPresent(UUID.self, forKey: .mealID)
        quickPick = try container.decodeIfPresent(QuickPick.self, forKey: .quickPick)
        leftoversFrom = try container.decodeIfPresent(UUID.self, forKey: .leftoversFrom)
        stashItemID = try container.decodeIfPresent(UUID.self, forKey: .stashItemID)
        prepSteps = try container.decode([ReminderPrep].self, forKey: .prepSteps)
        attendance = try container.decode([UUID: Bool].self, forKey: .attendance)
        checkedIn = try container.decodeIfPresent(Set<UUID>.self, forKey: .checkedIn) ?? []
        ratedBy = try container.decode(Set<UUID>.self, forKey: .ratedBy)
        hasLog = try container.decode(Bool.self, forKey: .hasLog)
        loggedMealID = try container.decodeIfPresent(UUID.self, forKey: .loggedMealID)
    }
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

    /// With answers the server hasn't got yet counted as if it had. They're what this person last said, and planning from the
    /// read alone would ask again, and bring back the prompt for a dinner they said they'd miss.
    func applying(_ answers: [CheckInAnswer]) -> ReminderSnapshot {
        guard !answers.isEmpty else { return self }
        return ReminderSnapshot(pulledAt: pulledAt, weeks: weeks.map { week in
            var week = week
            week.nights = week.nights.map { night in
                var night = night
                for answer in answers where answer.nightID == night.id {
                    night.attendance[answer.memberID] = answer.home
                    night.checkedIn.insert(answer.memberID)
                }
                return night
            }
            return week
        })
    }
}

/// What this device has already done about a reminder.
struct ReminderHistory: Equatable, Sendable {
    let id: String
    var sentAt: Date?
    var respondedAt: Date?
    /// "Remind me in an hour".
    var snoozedUntil: Date?
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

/// Each identifier carries the person, so what's left from someone else on this device never matches a plan, and the dish, so
/// one that changed is a different reminder and what was sent for the old dish doesn't count against the new one. A prep step
/// goes by its kind and lead time, never its place in the list, so editing one step can't hand its history, or its wording, to
/// another. `twin` tells apart steps that match on both. None of it is what the family typed, so rewording a step keeps its
/// history.
extension ReminderID {
    static func timeToPlan(me: UUID, week: CalendarDay) -> String {
        "\(prefix)\(me.uuidString).plan.\(week.isoString)"
    }

    static func prep(me: UUID, night: UUID, meal: UUID, kind: PrepKind, leadHours: Int, twin: Int = 0) -> String {
        "\(prefix)\(me.uuidString).prep.\(night.uuidString).\(meal.uuidString).\(kind.rawValue)-\(leadHours)-\(twin)"
    }

    static func afterDinner(me: UUID, night: UUID, meal: UUID) -> String {
        "\(prefix)\(me.uuidString).after.\(night.uuidString).\(meal.uuidString)"
    }

    static func checkIn(me: UUID, night: UUID) -> String {
        "\(prefix)\(me.uuidString).checkin.\(night.uuidString)"
    }

    static func roundup(me: UUID, week: CalendarDay) -> String {
        "\(prefix)\(me.uuidString).roundup.\(week.isoString)"
    }

    /// Whether this is an after-dinner prompt (or its follow-up), for any night.
    static func isAfterDinner(_ id: String) -> Bool { isReminder(id) && id.contains(".after.") }

    /// Whether this is an after-dinner prompt for that night, whichever dish it's about.
    static func isAfterDinner(_ id: String, night: UUID) -> Bool {
        id.contains(".after.\(night.uuidString).")
    }

    /// After-dinner prompts still in Notification Center that are no longer the question: rated (on any phone), marked out,
    /// or about a dish that isn't what was planned or logged. Their buttons would write over an answer, so they're taken back.
    /// A night the snapshot doesn't hold is left alone.
    static func answeredAfterDinner(_ delivered: [String], me: UUID, nights: [ReminderNight]) -> [String] {
        delivered.filter { id in
            guard let night = nights.first(where: { isAfterDinner(id, night: $0.id) }) else { return false }
            guard id.hasPrefix("\(prefix)\(me.uuidString).") else { return false }
            let stillAsked = night.mealID.map { meal in
                id == afterDinner(me: me, night: night.id, meal: meal) && night.attendance[me] == true
                    && !night.ratedBy.contains(me) && (!night.hasLog || night.loggedMealID == meal)
            } ?? false
            return !stillAsked
        }
    }
}
