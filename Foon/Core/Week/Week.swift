import Foundation
import Supabase

/// One planned week: seven nights from the shopping day, each with who's expected home.
struct Week: Equatable, Sendable {
    let planID: UUID
    let start: CalendarDay
    var approvedAt: Date?
    var nights: [WeekNight]
}

struct WeekNight: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: CalendarDay
    var effort: NightEffort
    var dinnerTime: String?
    var mealID: UUID?
    var mealName: String?
    var quickPick: QuickPick?
    var locked: Bool
    /// Member id → expected home. Members without a row (added after the week was made) are left off.
    var attendance: [UUID: Bool]
}

/// Reads and writes the planner's week. Planners own the plan, efforts, and attendance (row-level security).
struct WeekClient: Sendable {
    var week: @Sendable (_ householdID: UUID, _ start: CalendarDay) async throws -> Week?
    /// Builds the seven nights with attendance from everyone's usual schedule (`create_week`), or returns the week.
    var create: @Sendable (_ householdID: UUID, _ start: CalendarDay) async throws -> Week
    var setExpected: @Sendable (_ nightID: UUID, _ memberID: UUID, _ expected: Bool) async throws -> Void
    var setEffort: @Sendable (_ nightID: UUID, _ effort: NightEffort) async throws -> Void
}

extension WeekClient {
    static func live(_ client: SupabaseClient) -> WeekClient {
        let fetch: @Sendable (UUID, CalendarDay) async throws -> Week? = { householdID, start in
            let rows: [PlanWithNights] = try await client.from("plans")
                .select("""
                    id, week_start, approved_at, \
                    plan_nights(id, date, effort, dinner_time, meal_id, quick_pick, locked, meals(name), \
                    night_attendance(member_id, expected))
                    """)
                .eq("household_id", value: householdID)
                .eq("week_start", value: start.isoString)
                .limit(1)
                .execute()
                .value
            return rows.first?.week
        }
        return WeekClient(
            week: fetch,
            create: { householdID, start in
                try await client.rpc(
                    "create_week", params: ["target_household": householdID.uuidString, "start_date": start.isoString]
                )
                .execute()
                guard let week = try await fetch(householdID, start) else { throw LibraryClientError.notAllowed }
                return week
            },
            setExpected: { nightID, memberID, expected in
                let updated: [IDOnly] = try await client.from("night_attendance")
                    .update(["expected": expected])
                    .eq("plan_night_id", value: nightID)
                    .eq("member_id", value: memberID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            },
            setEffort: { nightID, effort in
                let updated: [IDOnly] = try await client.from("plan_nights")
                    .update(["effort": effort.rawValue])
                    .eq("id", value: nightID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            }
        )
    }
}

private struct IDOnly: Decodable, Sendable {
    let id: UUID
}

private struct PlanWithNights: Decodable, Sendable {
    struct Night: Decodable, Sendable {
        struct Meal: Decodable, Sendable { let name: String }
        struct Attendance: Decodable, Sendable {
            let memberID: UUID
            let expected: Bool

            enum CodingKeys: String, CodingKey {
                case expected
                case memberID = "member_id"
            }
        }

        let id: UUID
        let date: CalendarDay
        let effort: NightEffort
        let dinnerTime: String?
        let mealID: UUID?
        let quickPick: QuickPick?
        let locked: Bool
        let meals: Meal?
        let nightAttendance: [Attendance]

        enum CodingKeys: String, CodingKey {
            case id, date, effort, locked, meals
            case dinnerTime = "dinner_time"
            case mealID = "meal_id"
            case quickPick = "quick_pick"
            case nightAttendance = "night_attendance"
        }
    }

    let id: UUID
    let weekStart: CalendarDay
    let approvedAt: Date?
    let planNights: [Night]

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case approvedAt = "approved_at"
        case planNights = "plan_nights"
    }

    var week: Week {
        Week(planID: id, start: weekStart, approvedAt: approvedAt, nights: planNights.sorted { $0.date < $1.date }.map {
            WeekNight(id: $0.id, date: $0.date, effort: $0.effort, dinnerTime: $0.dinnerTime, mealID: $0.mealID,
                      mealName: $0.meals?.name, quickPick: $0.quickPick, locked: $0.locked,
                      attendance: Dictionary($0.nightAttendance.map { ($0.memberID, $0.expected) },
                                             uniquingKeysWith: { first, _ in first }))
        })
    }
}
