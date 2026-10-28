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
}

/// One person's reaction to a confirmed dinner. Changeable for 24 hours, then it's history.
struct Reaction: Equatable, Sendable, Decodable {
    let memberID: UUID
    let kind: ReactionKind
    let offTonight: Bool
    let comment: String?
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
    let reactions: [Reaction]

    init(id: UUID, nightID: UUID, date: CalendarDay, mealID: UUID?, mealName: String?, quickPick: QuickPick?,
         cookedByMemberID: UUID? = nil, leftovers: Bool? = nil, verified: Bool = true, reactions: [Reaction] = []) {
        self.id = id
        self.nightID = nightID
        self.date = date
        self.mealID = mealID
        self.mealName = mealName
        self.quickPick = quickPick
        self.cookedByMemberID = cookedByMemberID
        self.leftovers = leftovers
        self.verified = verified
        self.reactions = reactions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nightID = "night_id"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case cookedByMemberID = "cooked_by_member_id"
        case leftovers, verified, reactions
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
        reactions = try container.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
    }

    func reaction(of memberID: UUID) -> Reaction? {
        reactions.first { $0.memberID == memberID }
    }
}

/// A correction to a dinner log: "We had something else", leftovers, and who cooked. Every field is sent, so
/// switching from a meal to a quick pick clears the meal.
struct DinnerCorrection: Equatable, Sendable, Encodable {
    var mealID: UUID?
    var quickPick: QuickPick?
    var cookedByMemberID: UUID?
    var leftovers: Bool?

    init(_ log: DinnerLog) {
        mealID = log.mealID
        quickPick = log.quickPick
        cookedByMemberID = log.cookedByMemberID
        leftovers = log.leftovers
    }

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case cookedByMemberID = "cooked_by_member_id"
        case leftovers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mealID, forKey: .mealID)
        try container.encode(quickPick, forKey: .quickPick)
        try container.encode(cookedByMemberID, forKey: .cookedByMemberID)
        try container.encode(leftovers, forKey: .leftovers)
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
}

extension DinnerClient {
    static func live(_ client: SupabaseClient) -> DinnerClient {
        DinnerClient(
            logs: { householdID, since in
                let logs: [DinnerLog] = try await client.from("meal_logs")
                    .select("""
                        id, night_id, meal_id, quick_pick, cooked_by_member_id, leftovers, verified, \
                        plan_nights!inner(date), meals(name), \
                        reactions(member_id, reaction, off_tonight, comment, created_at)
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
            }
        )
    }
}

enum DinnerClientError: Error {
    /// The server changed nothing: the log is gone or this person may not change it.
    case notAllowed
}

private struct IDRow: Decodable { let id: UUID }
