import Foundation
import Supabase

/// Household and member reads and writes, as closures so tests and previews can swap them out.
/// Row-level security decides what each caller may do; the UI only hides what it would refuse.
struct HouseholdClient: Sendable {
    /// The caller's household, if they have one (one per person in v1).
    var myHousehold: @Sendable () async throws -> Household?
    /// Creates the household with its starting settings and the owner's profile, in one transaction.
    var createHousehold: @Sendable (_ name: String, _ emoji: String?, _ ownerFirstName: String,
                                    _ settings: HouseholdSettings) async throws -> Household
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
    /// The one plain sentence on onboarding's allergy screen; allergies can't be saved without it.
    var grantAllergyConsent: @Sendable (_ householdID: UUID, _ textVersion: String) async throws -> Void = { _, _ in }
    /// Replaces a member's allergies: standard allergens and Other text.
    var setAllergies: @Sendable (_ memberID: UUID, _ allergens: [Allergen], _ custom: [String]) async throws -> Void
        = { _, _, _ in }
    /// Merges these settings into the household's, keeping keys this version doesn't know.
    var updateSettings: @Sendable (_ householdID: UUID, _ settings: HouseholdSettings) async throws -> Void = { _, _ in }
    /// Everything in the household as JSON (planners only), for the data export.
    var exportHousehold: @Sendable (_ householdID: UUID) async throws -> Data = { _ in Data("{}".utf8) }
    /// Erases the household the caller owns, photos included, for everyone; their account stays.
    var deleteHousehold: @Sendable () async throws -> Void = { }
    /// Adds a stretch to the household's away dates as they are on the server, and returns the list; the server also
    /// brings the weeks already started into line.
    var addAwayDates: @Sendable (_ householdID: UUID, _ dates: AwayDates) async throws -> [AwayDates] = { _, _ in [] }
    /// Takes those nights out of the away dates as they are on the server, and returns the list.
    var removeAwayDates: @Sendable (_ householdID: UUID, _ dates: AwayDates) async throws -> [AwayDates] = { _, _ in [] }
    var attendanceTemplates: @Sendable (_ householdID: UUID) async throws -> [AttendanceTemplate] = { _ in [] }
    /// Saves everyone's usual schedule as it is on the server now, replacing a template with that name.
    var saveAttendanceTemplate: @Sendable (_ householdID: UUID, _ name: String) async throws -> AttendanceTemplate
        = { _, name in AttendanceTemplate(id: UUID(), name: name, schedules: [:]) }
    /// Makes a saved schedule everyone's usual one.
    var applyAttendanceTemplate: @Sendable (_ templateID: UUID) async throws -> Void = { _ in }
    var deleteAttendanceTemplate: @Sendable (_ templateID: UUID) async throws -> Void = { _ in }
}

/// Why Delete household didn't go through.
enum HouseholdDeletionError: Error, Equatable {
    /// The caller doesn't own a household (already deleted, or ownership moved): nothing to retry.
    case notOwner
    /// It may have stopped part-way (or we couldn't hear back); trying again finishes it.
    case unfinished
}

/// The wording version logged with allergy consent; a change in what it promises means a new version.
enum AllergyConsent {
    static let textVersion = "allergy-data-v1"
    /// Logged by "Load a sample family", where nobody read the sentence: the record says so.
    static let sampleVersion = "sample-family-v1"

    static var statement: String {
        String(localized: "Foon keeps these with your household so it can flag dishes. They're never sold, never used for ads, and never leave your devices for AI. Parents can delete them anytime.",
               comment: "Allergy consent: the one plain sentence parents agree to")
    }
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
            createHousehold: { name, emoji, ownerFirstName, settings in
                try await client.rpc(
                    "create_household",
                    params: CreateHouseholdParams(
                        householdName: name, householdEmoji: emoji, ownerFirstName: ownerFirstName,
                        householdSettings: settings
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
            },
            grantAllergyConsent: { householdID, textVersion in
                try await client.rpc("grant_allergy_consent", params: [
                    "target_household": householdID.uuidString, "wording": textVersion
                ]).execute()
            },
            setAllergies: { memberID, allergens, custom in
                try await client.rpc("set_member_allergies", params: SetAllergiesParams(
                    targetMember: memberID, allergens: allergens, custom: custom
                )).execute()
            },
            updateSettings: { householdID, settings in
                try await client.rpc("update_household_settings", params: SettingsParams(
                    targetHousehold: householdID, patch: settings
                )).execute()
            },
            exportHousehold: { householdID in
                try await client.rpc("export_household", params: ["target_household": householdID.uuidString])
                    .execute()
                    .data
            },
            deleteHousehold: {
                // The Edge Function removes the household's photos (service role) before the data.
                do {
                    try await client.functions.invoke(
                        "delete-account", options: FunctionInvokeOptions(body: ["scope": "household"])
                    )
                } catch FunctionsError.httpError(let code, _) where code == 403 {
                    throw HouseholdDeletionError.notOwner
                } catch {
                    throw HouseholdDeletionError.unfinished
                }
            },
            addAwayDates: { householdID, dates in
                try await client.rpc("add_away_dates", params: AwayDatesParams(
                    targetHousehold: householdID, firstNight: dates.from, lastNight: dates.to
                )).execute().value
            },
            removeAwayDates: { householdID, dates in
                try await client.rpc("remove_away_dates", params: AwayDatesParams(
                    targetHousehold: householdID, firstNight: dates.from, lastNight: dates.to
                )).execute().value
            },
            attendanceTemplates: { householdID in
                try await client.from("attendance_templates")
                    .select("id, name, schedules")
                    .eq("household_id", value: householdID)
                    .order("name")
                    .execute()
                    .value
            },
            saveAttendanceTemplate: { householdID, name in
                try await client.rpc("save_attendance_template", params: [
                    "target_household": householdID.uuidString, "template_name": name
                ]).execute().value
            },
            applyAttendanceTemplate: { templateID in
                try await client.rpc("apply_attendance_template", params: ["target_template": templateID]).execute()
            },
            deleteAttendanceTemplate: { templateID in
                try await client.from("attendance_templates").delete().eq("id", value: templateID).execute()
            }
        )
    }
}

private struct CreateHouseholdParams: Encodable, Sendable {
    let householdName: String
    let householdEmoji: String?
    let ownerFirstName: String
    let householdSettings: HouseholdSettings

    enum CodingKeys: String, CodingKey {
        case householdName = "household_name"
        case householdEmoji = "household_emoji"
        case ownerFirstName = "owner_first_name"
        case householdSettings = "household_settings"
    }

    // Every argument is sent, null included: PostgREST matches functions by argument names, so an
    // omitted emoji would look for a create_household that doesn't exist.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdName, forKey: .householdName)
        try container.encode(householdEmoji, forKey: .householdEmoji)
        try container.encode(ownerFirstName, forKey: .ownerFirstName)
        try container.encode(householdSettings, forKey: .householdSettings)
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

private struct SetAllergiesParams: Encodable, Sendable {
    let targetMember: UUID
    let allergens: [Allergen]
    let custom: [String]

    enum CodingKeys: String, CodingKey {
        case targetMember = "target_member"
        case allergens, custom
    }
}

private struct SettingsParams: Encodable, Sendable {
    let targetHousehold: UUID
    let patch: HouseholdSettings

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case patch
    }
}

private struct AwayDatesParams: Encodable, Sendable {
    let targetHousehold: UUID
    let firstNight: CalendarDay
    let lastNight: CalendarDay

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case firstNight = "first_night"
        case lastNight = "last_night"
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
