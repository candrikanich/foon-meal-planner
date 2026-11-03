import Foundation
import Supabase

/// One `notification_log` row as a device sends it. Type, night, and times: no text, and nothing about allergies.
struct NotificationLogEntry: Encodable, Equatable, Sendable {
    let id: UUID
    let type: String
    let nightID: UUID?
    let scheduledFor: Date
    let sentAt: Date?
    let respondedAt: Date?
    let response: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, response
        case nightID = "night_id"
        case scheduledFor = "scheduled_for"
        case sentAt = "sent_at"
        case respondedAt = "responded_at"
    }
}

/// Server access for reminders, as closures so tests and previews can swap them out.
struct NotificationClient: Sendable {
    /// The plans starting from `from` through `through`, with what reminders need from each night.
    var weeks: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ through: CalendarDay) async throws -> [ReminderWeek]
    /// The household's open ideas added since `since`, for counting: when, and whose (RLS keeps it to the household).
    var ideas: @Sendable (_ householdID: UUID, _ since: Date) async throws -> [ReminderIdea] = { _, _ in [] }
    /// Sends log rows (`record_notifications`), at most 200 at a time. The server only ever files them under the caller.
    var record: @Sendable (_ householdID: UUID, _ entries: [NotificationLogEntry]) async throws -> Void
    /// "Home" or "Not home" from the lock screen. The server takes it only for tonight.
    var answerCheckIn: @Sendable (_ nightID: UUID, _ memberID: UUID, _ home: Bool) async throws -> Void = { _, _, _ in }
    /// A reaction or "Wasn't home" from the after-dinner notification.
    var answerDinner: @Sendable (_ answer: DinnerAnswer) async throws -> Void = { _ in }
    /// This device's APNs token, filed under whoever is signed in (`register_push_device`).
    var registerPush: @Sendable (_ token: String, _ environment: String) async throws -> Void = { _, _ in }
    /// Takes this device's token off the server, whoever it's filed under (`unregister_push_device`).
    var unregisterPush: @Sendable (_ token: String) async throws -> Void = { _ in }
    /// When the server's pushes to this member went out since `since`, for the shared weekly budget.
    var pushesSent: @Sendable (_ householdID: UUID, _ memberID: UUID, _ since: Date) async throws -> [SentPush] = { _, _, _ in [] }
}

/// A server push that went out to this person, and whether it uses up the week's budget.
struct SentPush: Equatable, Sendable {
    let sentAt: Date
    /// `notification_log.type`.
    let type: String

    /// Plan's set and urgent items go whatever else this week held, on the server too (`push_outside_budget`).
    static let outsideBudget: Set<String> = ["plan_set", "urgent_item"]

    var countsTowardBudget: Bool { !Self.outsideBudget.contains(type) }
}

extension NotificationClient {
    static func live(_ client: SupabaseClient) -> NotificationClient {
        NotificationClient(
            weeks: { householdID, from, through in
                let plans: [ReminderPlanRow] = try await client.from("plans")
                    .select("id, week_start, approved_at, plan_nights(\(ReminderNightRow.columns))")
                    .eq("household_id", value: householdID)
                    .gte("week_start", value: from.isoString)
                    .lte("week_start", value: through.isoString)
                    .execute()
                    .value
                let nightIDs = plans.flatMap(\.planNights).map(\.id)
                let logs: [ReminderLogRow] = nightIDs.isEmpty ? [] : try await client.from("meal_logs")
                    .select("night_id, meal_id, reactions(member_id)")
                    .in("night_id", values: nightIDs)
                    .execute()
                    .value
                let byNight = Dictionary(logs.map { ($0.nightID, $0) }, uniquingKeysWith: { first, _ in first })
                return plans.map { $0.week(logs: byNight) }
            },
            ideas: { householdID, since in
                try await client.from("requests")
                    .select("created_at, requested_by_member_id, entered_by_member_id")
                    .eq("household_id", value: householdID)
                    .eq("status", value: "open")
                    .gte("created_at", value: since.ISO8601Format())
                    .execute()
                    .value
            },
            record: { householdID, entries in
                try await client.rpc("record_notifications", params: RecordParams(targetHousehold: householdID, entries: entries))
                    .execute()
            },
            answerCheckIn: { nightID, memberID, home in
                try await client.rpc("answer_check_in", params: CheckInParams(targetNight: nightID, targetMember: memberID, home: home))
                    .execute()
            },
            answerDinner: { answer in
                let target = ["target_night": answer.nightID.uuidString, "target_member": answer.memberID.uuidString]
                switch answer.answer {
                case .reaction(let kind):
                    try await client.rpc("react_to_dinner", params: target.merging(["kind": kind.rawValue]) { old, _ in old })
                        .execute()
                case .wasntHome:
                    try await client.rpc("set_not_home", params: target).execute()
                }
            },
            registerPush: { token, environment in
                try await client.rpc("register_push_device",
                                     params: ["device_token": token, "device_environment": environment]).execute()
            },
            unregisterPush: { token in
                try await client.rpc("unregister_push_device", params: ["device_token": token]).execute()
            },
            pushesSent: { householdID, memberID, since in
                let rows: [SentPushRow] = try await client.from("notification_log")
                    .select("sent_at, type")
                    .eq("household_id", value: householdID)
                    .eq("member_id", value: memberID)
                    .eq("channel", value: "push")
                    .gte("sent_at", value: since)
                    .execute()
                    .value
                return rows.map { SentPush(sentAt: $0.sentAt, type: $0.type) }
            }
        )
    }

    /// No server.
    static let preview = NotificationClient(weeks: { _, _, _ in [] }, record: { _, _ in })
}

private struct SentPushRow: Decodable, Sendable {
    let sentAt: Date
    let type: String

    enum CodingKeys: String, CodingKey {
        case sentAt = "sent_at"
        case type
    }
}

private struct CheckInParams: Encodable, Sendable {
    let targetNight: UUID
    let targetMember: UUID
    let home: Bool

    enum CodingKeys: String, CodingKey {
        case targetNight = "target_night"
        case targetMember = "target_member"
        case home
    }
}

private struct RecordParams: Encodable, Sendable {
    let targetHousehold: UUID
    let entries: [NotificationLogEntry]

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case entries
    }
}

private struct ReminderPlanRow: Decodable, Sendable {
    let id: UUID
    let weekStart: CalendarDay
    let approvedAt: Date?
    let planNights: [ReminderNightRow]

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case approvedAt = "approved_at"
        case planNights = "plan_nights"
    }

    func week(logs: [UUID: ReminderLogRow]) -> ReminderWeek {
        ReminderWeek(planID: id, start: weekStart, isApproved: approvedAt != nil,
                     nights: planNights.sorted { $0.date < $1.date }.map { $0.night(log: logs[$0.id]) })
    }
}

private struct ReminderNightRow: Decodable, Sendable {
    static let columns = """
        id, date, dinner_time, meal_id, quick_pick, leftovers_from, stash_item_id, meals(prep_steps), \
        night_attendance(member_id, expected, checked_in_at)
        """

    /// One step that won't read shouldn't cost the rest, or the night.
    struct Meal: Decodable, Sendable {
        let prepSteps: [PrepStep]

        enum CodingKeys: String, CodingKey {
            case prepSteps = "prep_steps"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prepSteps = ((try? container.decodeIfPresent(LenientPrepSteps.self, forKey: .prepSteps)) ?? nil)?.steps ?? []
        }
    }

    let id: UUID
    let date: CalendarDay
    let dinnerTime: String?
    let mealID: UUID?
    let quickPick: QuickPick?
    let leftoversFrom: UUID?
    let stashItemID: UUID?
    let meals: Meal?
    let nightAttendance: [PlanNightRow.Attendance]

    enum CodingKeys: String, CodingKey {
        case id, date, meals
        case dinnerTime = "dinner_time"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case leftoversFrom = "leftovers_from"
        case stashItemID = "stash_item_id"
        case nightAttendance = "night_attendance"
    }

    func night(log: ReminderLogRow?) -> ReminderNight {
        ReminderNight(id: id, date: date, dinnerTime: dinnerTime, mealID: mealID, quickPick: quickPick,
                      leftoversFrom: leftoversFrom, stashItemID: stashItemID, prepSteps: (meals?.prepSteps ?? []).compactMap(ReminderPrep.init),
                      attendance: Dictionary(nightAttendance.map { ($0.memberID, $0.expected) },
                                             uniquingKeysWith: { first, _ in first }),
                      checkedIn: Set(nightAttendance.filter { $0.checkedInAt != nil }.map(\.memberID)),
                      ratedBy: Set(log?.reactions.map(\.memberID) ?? []), hasLog: log != nil, loggedMealID: log?.mealID)
    }
}

private struct ReminderLogRow: Decodable, Sendable {
    struct Rating: Decodable, Sendable {
        let memberID: UUID

        enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
        }
    }

    let nightID: UUID
    let mealID: UUID?
    let reactions: [Rating]

    enum CodingKeys: String, CodingKey {
        case reactions
        case nightID = "night_id"
        case mealID = "meal_id"
    }
}
