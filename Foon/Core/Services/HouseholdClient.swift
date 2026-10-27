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
    /// Returns the code to share; it is shown once and stored only as a hash.
    var createInvite: @Sendable (_ memberID: UUID) async throws -> String
    var redeemInvite: @Sendable (_ code: String) async throws -> RedeemResult
    /// Profiles with an invite that is still open (parents only; others get none).
    var invitedMemberIDs: @Sendable (_ householdID: UUID) async throws -> Set<UUID>
    /// Kids whose parental consent is active.
    var parentalConsentMemberIDs: @Sendable (_ householdID: UUID) async throws -> Set<UUID>
    var recordParentalConsent: @Sendable (_ householdID: UUID, _ memberID: UUID) async throws -> Void
    /// Unlinks the kid's account at once (the database does it when consent is revoked).
    var revokeParentalConsent: @Sendable (_ memberID: UUID) async throws -> Void
}

extension HouseholdClient {
    static func live(_ client: SupabaseClient) -> HouseholdClient {
        HouseholdClient(
            myHousehold: {
                let rows: [Household] = try await client.from("households")
                    .select("id, name, emoji, owner, settings")
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
            },
            createInvite: { memberID in
                try await client.rpc("create_invite", params: ["target_member": memberID]).execute().value
            },
            redeemInvite: { code in
                try await client.rpc("redeem_invite", params: ["code": code]).execute().value
            },
            invitedMemberIDs: { householdID in
                let rows: [OpenInvite] = try await client.from("invites")
                    .select("member_id")
                    .eq("household_id", value: householdID)
                    .is("redeemed_at", value: nil)
                    .is("revoked_at", value: nil)
                    .gt("expires_at", value: Date())
                    .execute()
                    .value
                return Set(rows.map(\.memberID))
            },
            parentalConsentMemberIDs: { householdID in
                let rows: [OpenInvite] = try await client.from("consents")
                    .select("member_id")
                    .eq("household_id", value: householdID)
                    .eq("kind", value: "parental")
                    .is("revoked_at", value: nil)
                    .execute()
                    .value
                return Set(rows.map(\.memberID))
            },
            recordParentalConsent: { householdID, memberID in
                try await client.from("consents")
                    .insert(NewParentalConsent(householdID: householdID, memberID: memberID))
                    .execute()
            },
            revokeParentalConsent: { memberID in
                // The database stamps the real revocation time.
                try await client.from("consents")
                    .update(["revoked_at": Date()])
                    .eq("member_id", value: memberID)
                    .eq("kind", value: "parental")
                    .is("revoked_at", value: nil)
                    .execute()
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

    // Every argument is sent, null included: PostgREST matches functions by argument names, so an
    // omitted emoji would look for a create_household that doesn't exist.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdName, forKey: .householdName)
        try container.encode(householdEmoji, forKey: .householdEmoji)
        try container.encode(ownerFirstName, forKey: .ownerFirstName)
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

private struct OpenInvite: Decodable, Sendable {
    let memberID: UUID

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
    }
}

private struct NewParentalConsent: Encodable, Sendable {
    let householdID: UUID
    let memberID: UUID
    let kind = "parental"
    let textVersion = ParentalConsent.textVersion

    enum CodingKeys: String, CodingKey {
        case kind
        case householdID = "household_id"
        case memberID = "member_id"
        case textVersion = "text_version"
    }
}
