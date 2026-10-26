import Foundation
import Supabase

/// Household and member reads and writes, as closures so tests and previews can swap them out.
/// Row-level security decides what each caller may do; the UI only hides what it would refuse.
struct HouseholdClient: Sendable {
    /// The caller's household, if they have one (one per person in v1).
    var myHousehold: @Sendable () async throws -> Household?
    var createHousehold: @Sendable (_ name: String, _ emoji: String?, _ ownerFirstName: String) async throws -> Household
    var members: @Sendable (_ householdID: UUID) async throws -> [Member]
    var addMember: @Sendable (_ householdID: UUID, _ draft: MemberDraft) async throws -> Member
    var updateMember: @Sendable (_ memberID: UUID, _ changes: MemberChanges) async throws -> Member
}

extension HouseholdClient {
    static func live(_ client: SupabaseClient) -> HouseholdClient {
        HouseholdClient(
            myHousehold: {
                let rows: [Household] = try await client.from("households")
                    .select("id, name, emoji, owner")
                    .limit(1)
                    .execute()
                    .value
                return rows.first
            },
            createHousehold: { name, emoji, ownerFirstName in
                try await client.rpc(
                    "create_household",
                    params: CreateHouseholdParams(
                        householdName: name, householdEmoji: emoji, ownerFirstName: ownerFirstName
                    )
                )
                .execute()
                .value
            },
            members: { householdID in
                try await client.from("members")
                    .select()
                    .eq("household_id", value: householdID)
                    .order("created_at")
                    .execute()
                    .value
            },
            addMember: { householdID, draft in
                try await client.from("members")
                    .insert(NewMember(householdID: householdID, draft: draft))
                    .select()
                    .single()
                    .execute()
                    .value
            },
            updateMember: { memberID, changes in
                try await client.from("members")
                    .update(changes)
                    .eq("id", value: memberID)
                    .select()
                    .single()
                    .execute()
                    .value
            }
        )
    }
}

private struct CreateHouseholdParams: Encodable, Sendable {
    let householdName: String
    let householdEmoji: String?
    let ownerFirstName: String

    enum CodingKeys: String, CodingKey {
        case householdName = "household_name"
        case householdEmoji = "household_emoji"
        case ownerFirstName = "owner_first_name"
    }
}

private struct NewMember: Encodable, Sendable {
    let householdID: UUID
    let draft: MemberDraft

    private enum CodingKeys: String, CodingKey {
        case householdID = "household_id"
    }

    func encode(to encoder: Encoder) throws {
        try draft.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdID, forKey: .householdID)
    }
}
