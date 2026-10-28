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
    /// The chip Build my week gave the pick ("Haven't had it in 3 weeks").
    var reason: String? = nil
}

/// One night's pick, as `set_nights` saves it. No meal and no quick pick clears the night.
struct NightUpdate: Equatable, Sendable, Encodable {
    let nightID: UUID
    var mealID: UUID?
    var quickPick: QuickPick?
    var reason: String?
    /// Saved locked when true (a tradition); unlocked otherwise.
    var locked: Bool?

    private enum CodingKeys: String, CodingKey {
        case nightID = "id"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case reason, locked
    }
}

/// Reads and writes the planner's week. Planners own the plan, efforts, and attendance (row-level security).
struct WeekClient: Sendable {
    var week: @Sendable (_ householdID: UUID, _ start: CalendarDay) async throws -> Week?
    /// Builds the seven nights with attendance from everyone's usual schedule (`create_week`), or returns the week.
    var create: @Sendable (_ householdID: UUID, _ start: CalendarDay) async throws -> Week
    var setExpected: @Sendable (_ nightID: UUID, _ memberID: UUID, _ expected: Bool) async throws -> Void
    var setEffort: @Sendable (_ nightID: UUID, _ effort: NightEffort) async throws -> Void
    var setLocked: @Sendable (_ nightID: UUID, _ locked: Bool) async throws -> Void
    /// Saves several nights' picks in one transaction.
    var setNights: @Sendable (_ planID: UUID, _ nights: [NightUpdate]) async throws -> Void
    /// Swap: one night's pick and lock, set directly (a planner may swap a locked night).
    var setNight: @Sendable (_ night: NightUpdate, _ locked: Bool) async throws -> Void
    /// Approves the week and writes its weekly list in one transaction.
    var approve: @Sendable (_ planID: UUID, _ lines: [WeeklyList.Line]) async throws -> Void = { _, _ in }
    var traditions: @Sendable (_ householdID: UUID) async throws -> [Tradition] = { _ in [] }
    /// Sets or replaces a weekday's tradition; nil removes it.
    var setTradition: @Sendable (_ householdID: UUID, _ weekday: Int, _ tradition: Tradition?) async throws -> Void
        = { _, _, _ in }
}

extension WeekClient {
    static func live(_ client: SupabaseClient) -> WeekClient {
        let fetch: @Sendable (UUID, CalendarDay) async throws -> Week? = { householdID, start in
            let rows: [PlanWithNights] = try await client.from("plans")
                .select("id, week_start, approved_at, plan_nights(\(PlanNightRow.columns))")
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
            },
            setLocked: { nightID, locked in
                let updated: [IDOnly] = try await client.from("plan_nights")
                    .update(["locked": locked])
                    .eq("id", value: nightID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            },
            setNights: { planID, nights in
                try await client.rpc("set_nights", params: SetNightsParams(targetPlan: planID, nights: nights)).execute()
            },
            setNight: { night, locked in
                let updated: [IDOnly] = try await client.from("plan_nights")
                    .update(NightPatch(update: night, locked: locked))
                    .eq("id", value: night.nightID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            },
            approve: { planID, lines in
                try await client.rpc("approve_plan", params: ApproveParams(targetPlan: planID, lines: lines)).execute()
            },
            traditions: { householdID in
                try await client.from("traditions")
                    .select("weekday, meal_id, quick_pick, name")
                    .eq("household_id", value: householdID)
                    .order("weekday")
                    .execute()
                    .value
            },
            setTradition: { householdID, weekday, tradition in
                guard let tradition else {
                    try await client.from("traditions").delete()
                        .eq("household_id", value: householdID).eq("weekday", value: weekday).execute()
                    return
                }
                try await client.rpc("set_tradition", params: SetTraditionParams(
                    householdID: householdID, weekday: weekday, tradition: tradition
                )).execute()
            }
        )
    }
}

private struct ApproveParams: Encodable, Sendable {
    struct Line: Encodable, Sendable {
        let line: WeeklyList.Line

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case quantity, note, staple
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(line.itemID, forKey: .itemID)
            try container.encodeIfPresent(line.quantity, forKey: .quantity)
            try container.encodeIfPresent(line.note, forKey: .note)
            try container.encode(line.isStaple, forKey: .staple)
        }
    }

    let targetPlan: UUID
    let lines: [Line]

    init(targetPlan: UUID, lines: [WeeklyList.Line]) {
        self.targetPlan = targetPlan
        self.lines = lines.map(Line.init)
    }

    enum CodingKeys: String, CodingKey {
        case targetPlan = "target_plan"
        case lines
    }
}

/// Every argument sent, nulls included: PostgREST matches functions by argument names.
private struct SetTraditionParams: Encodable, Sendable {
    let householdID: UUID
    let weekday: Int
    let tradition: Tradition

    enum CodingKeys: String, CodingKey {
        case householdID = "target_household"
        case weekday = "tradition_weekday"
        case meal = "tradition_meal"
        case quickPick = "tradition_quick_pick"
        case name = "tradition_name"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdID, forKey: .householdID)
        try container.encode(weekday, forKey: .weekday)
        try container.encode(tradition.pick.mealID, forKey: .meal)
        try container.encode(tradition.pick.quickPick, forKey: .quickPick)
        try container.encode(tradition.name, forKey: .name)
    }
}

/// Every column written, nulls included, so a swap from a meal to a quick pick clears the meal.
private struct NightPatch: Encodable, Sendable {
    let update: NightUpdate
    let locked: Bool

    enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case reason, locked
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(update.mealID, forKey: .mealID)
        try container.encode(update.quickPick, forKey: .quickPick)
        try container.encode(update.reason, forKey: .reason)
        try container.encode(locked, forKey: .locked)
    }
}

private struct SetNightsParams: Encodable, Sendable {
    let targetPlan: UUID
    let nights: [NightUpdate]

    enum CodingKeys: String, CodingKey {
        case targetPlan = "target_plan"
        case nights
    }
}

private struct IDOnly: Decodable, Sendable {
    let id: UUID
}

/// One `plan_nights` row with its meal's name and attendance, as `plans` and the after-dinner card select it.
struct PlanNightRow: Decodable, Sendable {
    struct Meal: Decodable, Sendable { let name: String }
    struct Attendance: Decodable, Sendable {
        let memberID: UUID
        let expected: Bool

        enum CodingKeys: String, CodingKey {
            case expected
            case memberID = "member_id"
        }
    }

    /// The columns to select for it.
    static let columns = """
        id, date, effort, dinner_time, meal_id, quick_pick, locked, reason, meals(name), \
        night_attendance(member_id, expected)
        """

    let id: UUID
    let date: CalendarDay
    let effort: NightEffort
    let dinnerTime: String?
    let mealID: UUID?
    let quickPick: QuickPick?
    let locked: Bool
    let reason: String?
    let meals: Meal?
    let nightAttendance: [Attendance]

    enum CodingKeys: String, CodingKey {
        case id, date, effort, locked, reason, meals
        case dinnerTime = "dinner_time"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case nightAttendance = "night_attendance"
    }

    var night: WeekNight {
        WeekNight(id: id, date: date, effort: effort, dinnerTime: dinnerTime, mealID: mealID, mealName: meals?.name,
                  quickPick: quickPick, locked: locked,
                  attendance: Dictionary(nightAttendance.map { ($0.memberID, $0.expected) },
                                         uniquingKeysWith: { first, _ in first }),
                  reason: reason)
    }
}

private struct PlanWithNights: Decodable, Sendable {
    let id: UUID
    let weekStart: CalendarDay
    let approvedAt: Date?
    let planNights: [PlanNightRow]

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case approvedAt = "approved_at"
        case planNights = "plan_nights"
    }

    var week: Week {
        Week(planID: id, start: weekStart, approvedAt: approvedAt,
             nights: planNights.sorted { $0.date < $1.date }.map(\.night))
    }
}
