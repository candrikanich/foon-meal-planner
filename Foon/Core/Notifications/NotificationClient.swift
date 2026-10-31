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
    /// Sends log rows (`record_notifications`), at most 200 at a time. The server only ever files them under the caller.
    var record: @Sendable (_ householdID: UUID, _ entries: [NotificationLogEntry]) async throws -> Void
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
            record: { householdID, entries in
                try await client.rpc("record_notifications", params: RecordParams(targetHousehold: householdID, entries: entries))
                    .execute()
            }
        )
    }

    /// No server.
    static let preview = NotificationClient(weeks: { _, _, _ in [] }, record: { _, _ in })
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
        night_attendance(member_id, expected)
        """

    /// One step that won't read shouldn't cost the rest, or the night.
    struct Meal: Decodable, Sendable {
        struct LenientStep: Decodable, Sendable {
            let step: PrepStep?

            init(from decoder: Decoder) throws {
                step = try? PrepStep(from: decoder)
            }
        }

        let prepSteps: [PrepStep]

        enum CodingKeys: String, CodingKey {
            case prepSteps = "prep_steps"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prepSteps = ((try? container.decodeIfPresent([LenientStep].self, forKey: .prepSteps)) ?? nil)?
                .compactMap(\.step) ?? []
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
