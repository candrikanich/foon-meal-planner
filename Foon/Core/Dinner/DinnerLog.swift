import Foundation
import Supabase

/// How someone felt about a dish (docs/spec.md → After-dinner loop). Always the food, never the cook.
enum ReactionKind: String, Codable, CaseIterable, Sendable {
    case favorite
    case good
    case notForMe = "not_for_me"
    case tiredOfIt = "tired_of_it"

    var title: String {
        switch self {
        case .favorite: String(localized: "Favorite")
        case .good: String(localized: "Good")
        case .notForMe: String(localized: "Not for me")
        case .tiredOfIt: String(localized: "Tired of it")
        }
    }

    var systemImage: String {
        switch self {
        case .favorite: "heart.fill"
        case .good: "hand.thumbsup"
        case .notForMe: "hand.thumbsdown"
        case .tiredOfIt: "zzz"
        }
    }
}

/// One person's reaction to a confirmed dinner. Changeable for 24 hours, then it's history.
struct Reaction: Equatable, Sendable, Decodable {
    let memberID: UUID
    let kind: ReactionKind
    let offTonight: Bool
    /// Not read from the server any more: comments are shown from `meal_comments`, which leaves hidden ones out.
    var comment: String? = nil
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case kind = "reaction"
        case offTonight = "off_tonight"
        case comment
        case createdAt = "created_at"
    }
}

/// A confirmed (or, with no answer, overnight-saved) dinner: what was actually eaten, who cooked, and leftovers.
struct DinnerLog: Identifiable, Equatable, Sendable, Decodable {
    let id: UUID
    let nightID: UUID
    let date: CalendarDay
    let mealID: UUID?
    let mealName: String?
    let quickPick: QuickPick?
    let cookedByMemberID: UUID?
    let leftovers: Bool?
    /// False when saved overnight because nobody answered.
    let verified: Bool
    /// Whoever answered first: they get the leftovers and who-cooked questions.
    let confirmedByMemberID: UUID?
    let reactions: [Reaction]

    init(id: UUID, nightID: UUID, date: CalendarDay, mealID: UUID?, mealName: String?, quickPick: QuickPick?,
         cookedByMemberID: UUID? = nil, leftovers: Bool? = nil, verified: Bool = true, confirmedByMemberID: UUID? = nil,
         reactions: [Reaction] = []) {
        self.id = id
        self.nightID = nightID
        self.date = date
        self.mealID = mealID
        self.mealName = mealName
        self.quickPick = quickPick
        self.cookedByMemberID = cookedByMemberID
        self.leftovers = leftovers
        self.verified = verified
        self.confirmedByMemberID = confirmedByMemberID
        self.reactions = reactions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nightID = "night_id"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case cookedByMemberID = "cooked_by_member_id"
        case leftovers, verified, reactions
        case confirmedByMemberID = "confirmed_by_member_id"
        case night = "plan_nights"
        case meal = "meals"
    }

    private struct Night: Decodable { let date: CalendarDay }
    private struct Meal: Decodable { let name: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nightID = try container.decode(UUID.self, forKey: .nightID)
        date = try container.decode(Night.self, forKey: .night).date
        mealID = try container.decodeIfPresent(UUID.self, forKey: .mealID)
        mealName = try container.decodeIfPresent(Meal.self, forKey: .meal)?.name
        quickPick = try container.decodeIfPresent(QuickPick.self, forKey: .quickPick)
        cookedByMemberID = try container.decodeIfPresent(UUID.self, forKey: .cookedByMemberID)
        leftovers = try container.decodeIfPresent(Bool.self, forKey: .leftovers)
        verified = try container.decode(Bool.self, forKey: .verified)
        confirmedByMemberID = try container.decodeIfPresent(UUID.self, forKey: .confirmedByMemberID)
        reactions = try container.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
    }

    func reaction(of memberID: UUID) -> Reaction? {
        reactions.first { $0.memberID == memberID }
    }
}

/// A correction to a dinner log. Each kind sends only its own columns, so two phones answering different questions
/// never overwrite each other's answers with stale ones.
enum DinnerCorrection: Equatable, Sendable, Encodable {
    /// "We had something else": a dish or a quick pick (sending both clears the other).
    case dish(mealID: UUID?, quickPick: QuickPick?)
    /// The first responder's follow-up.
    case extras(leftovers: Bool, cookedByMemberID: UUID?)

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case cookedByMemberID = "cooked_by_member_id"
        case leftovers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dish(let mealID, let quickPick):
            try container.encode(mealID, forKey: .mealID)
            try container.encode(quickPick, forKey: .quickPick)
        case .extras(let leftovers, let cook):
            try container.encode(leftovers, forKey: .leftovers)
            try container.encode(cook, forKey: .cookedByMemberID)
        }
    }
}

/// Dinner logs and reactions, as closures so tests and previews can swap them out. Row-level security decides who
/// may react for whom: yourself, or a profile nobody has claimed (pass the phone).
struct DinnerClient: Sendable {
    /// Logs for nights on or after `since`, oldest first, with everyone's reactions.
    var logs: @Sendable (_ householdID: UUID, _ since: CalendarDay) async throws -> [DinnerLog]
    /// Confirms the planned dinner (or verifies one saved overnight). Returns the log's id.
    var confirm: @Sendable (_ nightID: UUID) async throws -> UUID
    /// One tap: confirms the dinner and saves or changes a person's reaction. Returns the log's id.
    var react: @Sendable (_ nightID: UUID, _ memberID: UUID, _ kind: ReactionKind) async throws -> UUID
    var correct: @Sendable (_ logID: UUID, _ correction: DinnerCorrection) async throws -> Void
    /// The household's nights between two dates, whatever week they're in (last night may be last week's).
    var nights: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ through: CalendarDay) async throws -> [WeekNight]
    /// "Wasn't home": for yourself, or a profile nobody has claimed, on a night that's happened.
    var setNotHome: @Sendable (_ nightID: UUID, _ memberID: UUID) async throws -> Void
    /// Thanks for dinners on or after `since`.
    var thanks: @Sendable (_ householdID: UUID, _ since: CalendarDay) async throws -> [ChefThanks] = { _, _ in [] }
    /// "Thanks, chef", from your own profile.
    var thankTheChef: @Sendable (_ logID: UUID) async throws -> Void = { _ in }
}

/// One "Thanks, chef": from whom, for which dinner.
struct ChefThanks: Equatable, Sendable, Decodable {
    let logID: UUID
    let fromMemberID: UUID

    private enum CodingKeys: String, CodingKey {
        case logID = "meal_log_id"
        case fromMemberID = "from_member_id"
    }
}

extension DinnerClient {
    static func live(_ client: SupabaseClient) -> DinnerClient {
        DinnerClient(
            logs: { householdID, since in
                let logs: [DinnerLog] = try await client.from("meal_logs")
                    .select("""
                        id, night_id, meal_id, quick_pick, cooked_by_member_id, leftovers, verified, \
                        confirmed_by_member_id, \
                        plan_nights!inner(date), meals(name), \
                        reactions(member_id, reaction, off_tonight, created_at)
                        """)
                    .eq("household_id", value: householdID)
                    .gte("plan_nights.date", value: since.isoString)
                    .execute()
                    .value
                return logs.sorted { $0.date < $1.date }
            },
            confirm: { nightID in
                try await client.rpc("confirm_dinner", params: ["target_night": nightID]).execute().value
            },
            react: { nightID, memberID, kind in
                try await client.rpc("react_to_dinner", params: [
                    "target_night": nightID.uuidString, "target_member": memberID.uuidString, "kind": kind.rawValue
                ]).execute().value
            },
            correct: { logID, correction in
                let updated: [IDRow] = try await client.from("meal_logs")
                    .update(correction)
                    .eq("id", value: logID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw DinnerClientError.notAllowed }
            },
            nights: { householdID, from, through in
                let rows: [PlanNightRow] = try await client.from("plan_nights")
                    .select(PlanNightRow.columns)
                    .eq("household_id", value: householdID)
                    .gte("date", value: from.isoString)
                    .lte("date", value: through.isoString)
                    .order("date")
                    .execute()
                    .value
                return rows.map(\.night)
            },
            setNotHome: { nightID, memberID in
                try await client.rpc("set_not_home", params: [
                    "target_night": nightID.uuidString, "target_member": memberID.uuidString
                ]).execute()
            },
            thanks: { householdID, since in
                try await client.from("chef_thanks")
                    .select("meal_log_id, from_member_id, meal_logs!inner(plan_nights!inner(date))")
                    .eq("household_id", value: householdID)
                    .gte("meal_logs.plan_nights.date", value: since.isoString)
                    .execute()
                    .value
            },
            thankTheChef: { logID in
                try await client.rpc("thank_the_chef", params: ["target_log": logID.uuidString]).execute()
            }
        )
    }
}

enum DinnerClientError: Error {
    /// The server changed nothing: the log is gone or this person may not change it.
    case notAllowed
}

private struct IDRow: Decodable { let id: UUID }
