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
    /// Emails the parent the consent notice (COPPA email plus, #275); `email` only after a `.noEmail` answer.
    /// A refusal throws `ParentalConsentError`.
    var requestParentalConsent: @Sendable (_ memberID: UUID, _ email: String?) async throws -> ParentalConsentAnswer
    /// The household's consent requests, newest first (parents only; others get none).
    var parentalConsentRequests: @Sendable (_ householdID: UUID) async throws -> [ParentalConsentRequest] = { _ in [] }
    /// Unlinks the kid's account at once (the database does it when consent is revoked).
    var revokeParentalConsent: @Sendable (_ memberID: UUID) async throws -> Void
    /// Deletes a kid's profile, everything about them, and their sign-in account, at once (`delete_kid`, parents only).
    var deleteKid: @Sendable (_ memberID: UUID) async throws -> Void = { _ in }
    /// The one plain sentence on onboarding's allergy screen; allergies can't be saved without it.
    var grantAllergyConsent: @Sendable (_ householdID: UUID, _ textVersion: String) async throws -> Void = { _, _ in }
    /// Replaces a member's allergies: standard allergens and Other text.
    var setAllergies: @Sendable (_ memberID: UUID, _ allergens: [Allergen], _ custom: [String]) async throws -> Void
        = { _, _, _ in }
    /// Whether the household keeps allergies now, or ever agreed to (anyone in the household may read the consent log).
    var allergyAlerts: @Sendable (_ householdID: UUID) async throws -> AllergyAlerts = { _ in .neverOn }
    /// Family → Allergy alerts off (parents): revokes the household's consent, and the database erases every allergy.
    var revokeAllergyConsent: @Sendable (_ householdID: UUID) async throws -> Void = { _ in }
    /// Merges these settings into the household's, keeping keys this version doesn't know.
    var updateSettings: @Sendable (_ householdID: UUID, _ settings: HouseholdSettings) async throws -> Void = { _, _ in }
    /// Saves only the kitchen's keys, so a stale copy of anything else can't go with them.
    var updateKitchen: @Sendable (_ householdID: UUID, _ kitchen: HouseholdSettings.Kitchen) async throws -> Void = { _, _ in }
    /// Saves only what the Rhythm screen changed, so a stale copy of anything else can't go with it.
    var updateRhythm: @Sendable (_ householdID: UUID, _ changes: RhythmChanges) async throws -> Void = { _, _ in }
    /// Saves only the time zone, for a household that doesn't have one.
    var saveTimeZone: @Sendable (_ householdID: UUID, _ timeZone: String) async throws -> Void = { _, _ in }
    /// The day the household's latest plan starts, if it has one.
    var latestWeekStart: @Sendable (_ householdID: UUID) async throws -> CalendarDay? = { _ in nil }
    /// Sets or (nil) takes away one food's rule, in the list as it is on the server, and returns the list.
    var setFoodRule: @Sendable (_ householdID: UUID, _ avoid: FoodRule.Avoid, _ nights: FoodRule.Nights?) async throws -> [FoodRule]
        = { _, _, _ in [] }
    /// Turns one dinner job on or off, in the setting as it is on the server, and returns the setting.
    var setDinnerJob: @Sendable (_ householdID: UUID, _ job: DinnerJob, _ isOn: Bool) async throws -> DinnerJobSettings
        = { _, _, _ in DinnerJobSettings() }
    /// Puts one person in the rotation or leaves them out, the same way.
    var setDinnerJobPerson: @Sendable (_ householdID: UUID, _ memberID: UUID, _ isIn: Bool) async throws -> DinnerJobSettings
        = { _, _, _ in DinnerJobSettings() }
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
    /// The Family tab's "This month" counts for these days, both included, as the caller's row-level security allows.
    var familyStats: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ to: CalendarDay) async throws -> FamilyStats
        = { _, _, _ in FamilyStats() }
    /// This Week's recap of a finished week (`week_recap`): who cooked, the hit, and a forgotten favorite.
    var weekRecap: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ to: CalendarDay) async throws
        -> WeekRecapFacts = { _, _, _ in WeekRecapFacts() }
    /// Who tried a dish new to them in these days, both included (`tried_new`), for a member's profile.
    var triedNew: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ to: CalendarDay) async throws
        -> [TriedNewDishes] = { _, _, _ in [] }
    /// Who's pitching in over these days, both included (`engagement`): planners only, which the server enforces.
    var engagement: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ to: CalendarDay) async throws
        -> EngagementFacts = { _, _, _ in EngagementFacts() }
    /// "Your year in dinners" for one calendar year by the household's day (`year_recap`), through a day when given.
    var yearRecap: @Sendable (_ householdID: UUID, _ year: Int, _ through: CalendarDay?) async throws -> YearRecapFacts
        = { _, _, _ in YearRecapFacts() }
    /// Someone's own notification preset (`set_member_preset`); nil follows the household's.
    var setMemberPreset: @Sendable (_ memberID: UUID, _ preset: HouseholdSettings.NotificationPreset?) async throws -> Void
        = { _, _ in }
    /// Logged dinners with these night dates, both included, for the dinner memories timeline. Approval and "at the
    /// table" are judged in `DinnerMemories`, so a page with no logs at all can tell the timeline it's reached the end.
    var dinnerMemories: @Sendable (_ householdID: UUID, _ from: CalendarDay, _ through: CalendarDay) async throws
        -> [MemoryLog] = { _, _, _ in [] }
    /// The household's oldest night with a dinner logged, nil if none: where the timeline's paging can stop.
    var oldestDinnerLog: @Sendable (_ householdID: UUID) async throws -> CalendarDay? = { _ in nil }
}

/// Why Delete household didn't go through.
enum HouseholdDeletionError: Error, Equatable {
    /// The caller doesn't own a household (already deleted, or ownership moved): nothing to retry.
    case notOwner
    /// It may have stopped part-way (or we couldn't hear back); trying again finishes it.
    case unfinished
}

/// The wording version logged with allergy consent; a change in what it promises means a new version. Consent is asked
/// once: a household that agreed to an earlier version isn't asked again, and its record stays valid.
enum AllergyConsent {
    /// v2 (#280): names who receives allergies and how to withdraw (Washington MHMDA .030(2)).
    static let textVersion = "allergy-data-v2"
    /// Logged by "Load a sample family", where nobody read the sentence: the record says so.
    static let sampleVersion = "sample-family-v1"

    static var statement: String {
        String(localized: """
        Foon keeps these so it can flag dishes. Only your household and our hosting provider, which stores them for \
        us, receive them. They're never sold, never used for ads, and never leave your devices for AI. A parent can \
        withdraw anytime in Family → Allergy alerts, which erases them all.
        """, comment: """
            Allergy consent parents agree to. Must say exactly what the English says; see AllergyConsent.textVersion.
            """)
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
            requestParentalConsent: { memberID, email in
                let options = FunctionInvokeOptions(body: ConsentAsk(memberID: memberID, email: email))
                do {
                    return try await client.functions.invoke("parental-consent", options: options) { data, response in
                        try ParentalConsentAnswer.decode(status: response.statusCode, body: data)
                    }
                } catch FunctionsError.httpError(let code, let data) {
                    return try ParentalConsentAnswer.decode(status: code, body: data)
                }
            },
            parentalConsentRequests: { householdID in
                try await client.from("parental_consent_requests")
                    .select(ParentalConsentRequest.columns)
                    .eq("household_id", value: householdID)
                    .order("created_at", ascending: false)
                    .execute()
                    .value
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
            deleteKid: { memberID in
                try await client.rpc("delete_kid", params: ["target_member": memberID]).execute()
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
            allergyAlerts: { householdID in
                let rows: [ConsentState] = try await client.from("consents")
                    .select("revoked_at")
                    .eq("household_id", value: householdID)
                    .eq("kind", value: "allergy_data")
                    .execute()
                    .value
                return AllergyAlerts(revokedAt: rows.map(\.revokedAt))
            },
            revokeAllergyConsent: { householdID in
                try await client.rpc("revoke_allergy_consent", params: [
                    "target_household": householdID.uuidString
                ]).execute()
            },
            updateSettings: { householdID, settings in
                try await client.rpc("update_household_settings", params: SettingsParams(
                    targetHousehold: householdID, patch: settings
                )).execute()
            },
            updateKitchen: { householdID, kitchen in
                try await client.rpc("update_household_settings", params: KitchenParams(
                    targetHousehold: householdID, patch: kitchen
                )).execute()
            },
            updateRhythm: { householdID, changes in
                try await client.rpc("update_household_settings", params: RhythmParams(
                    targetHousehold: householdID, patch: changes
                )).execute()
            },
            saveTimeZone: { householdID, timeZone in
                try await client.rpc("update_household_settings", params: TimeZoneParams(
                    targetHousehold: householdID, patch: ["time_zone": timeZone]
                )).execute()
            },
            latestWeekStart: { householdID in
                let plans: [StartedWeek] = try await client.from("plans")
                    .select("week_start")
                    .eq("household_id", value: householdID)
                    .order("week_start", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                return plans.first?.weekStart
            },
            setFoodRule: { householdID, avoid, nights in
                let rules: [FoodRule.Lenient] = try await client.rpc("set_food_rule", params: FoodRuleParams(
                    targetHousehold: householdID, avoid: avoid, nights: nights
                )).execute().value
                return rules.compactMap(\.rule)
            },
            setDinnerJob: { householdID, job, isOn in
                try await client.rpc("set_dinner_job", params: DinnerJobParams(
                    targetHousehold: householdID, job: job.rawValue, isOn: isOn
                )).execute().value
            },
            setDinnerJobPerson: { householdID, memberID, isIn in
                try await client.rpc("set_dinner_job_person", params: DinnerJobPersonParams(
                    targetHousehold: householdID, targetMember: memberID, isIn: isIn
                )).execute().value
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
                let deleted: [DeletedTemplate] = try await client.from("attendance_templates")
                    .delete()
                    .eq("id", value: templateID)
                    .select("id")
                    .execute()
                    .value
                if deleted.isEmpty { throw AttendanceTemplateError.notDeleted }
            },
            familyStats: { householdID, from, to in
                try await client.rpc("family_stats", params: FamilyStatsParams(
                    targetHousehold: householdID, fromDate: from, toDate: to
                )).execute().value
            },
            weekRecap: { householdID, from, to in
                try await client.rpc("week_recap", params: FamilyStatsParams(
                    targetHousehold: householdID, fromDate: from, toDate: to
                )).execute().value
            },
            triedNew: { householdID, from, to in
                try await client.rpc("tried_new", params: FamilyStatsParams(
                    targetHousehold: householdID, fromDate: from, toDate: to
                )).execute().value
            },
            engagement: { householdID, from, to in
                try await client.rpc("engagement", params: FamilyStatsParams(
                    targetHousehold: householdID, fromDate: from, toDate: to
                )).execute().value
            },
            yearRecap: { householdID, year, through in
                try await client.rpc("year_recap", params: YearRecapParams(targetHousehold: householdID,
                                                                           targetYear: year, through: through))
                    .execute().value
            },
            setMemberPreset: { memberID, preset in
                try await client.rpc("set_member_preset", params: MemberPresetParams(targetMember: memberID, preset: preset))
                    .execute()
            },
            dinnerMemories: { householdID, from, through in
                try await client.from("meal_logs")
                    .select(MemoryLog.columns)
                    .eq("household_id", value: householdID)
                    .gte("plan_nights.date", value: from.isoString)
                    .lte("plan_nights.date", value: through.isoString)
                    .execute()
                    .value
            },
            oldestDinnerLog: { householdID in
                // From plan_nights, so the order sorts the rows: ordering by an embedded column wouldn't.
                let rows: [NightDate] = try await client.from("plan_nights")
                    .select("date, meal_logs!inner(id)")
                    .eq("household_id", value: householdID)
                    .order("date")
                    .limit(1)
                    .execute()
                    .value
                return rows.first?.date
            }
        )
    }
}

/// Sends `preset` even when it's nil (follow the household): PostgREST finds the function by its argument names.
struct MemberPresetParams: Encodable, Sendable {
    let targetMember: UUID
    let preset: HouseholdSettings.NotificationPreset?

    private enum CodingKeys: String, CodingKey {
        case targetMember = "target_member"
        case preset
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetMember, forKey: .targetMember)
        try container.encode(preset, forKey: .preset)
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

private struct KitchenParams: Encodable, Sendable {
    let targetHousehold: UUID
    let patch: HouseholdSettings.Kitchen

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case patch
    }
}

private struct RhythmParams: Encodable, Sendable {
    let targetHousehold: UUID
    let patch: RhythmChanges

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case patch
    }
}

private struct TimeZoneParams: Encodable, Sendable {
    let targetHousehold: UUID
    let patch: [String: String]

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case patch
    }
}

private struct StartedWeek: Decodable, Sendable {
    let weekStart: CalendarDay

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
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

/// Every argument is sent: PostgREST picks the function by its argument names. `week_recap`, `tried_new` and
/// `engagement` take the same ones.
private struct FamilyStatsParams: Encodable, Sendable {
    let targetHousehold: UUID
    let fromDate: CalendarDay
    let toDate: CalendarDay

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case fromDate = "from_date"
        case toDate = "to_date"
    }
}

/// `through` is always sent, null for a whole year, so PostgREST matches the function by all three argument names.
private struct NightDate: Decodable, Sendable {
    let date: CalendarDay
}

private struct YearRecapParams: Encodable, Sendable {
    let targetHousehold: UUID
    let targetYear: Int
    let through: CalendarDay?

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case targetYear = "target_year"
        case through
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetHousehold, forKey: .targetHousehold)
        try container.encode(targetYear, forKey: .targetYear)
        try container.encode(through, forKey: .through)
    }
}

private struct DeletedTemplate: Decodable, Sendable {
    let id: UUID
}

private struct ConsentState: Decodable, Sendable {
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case revokedAt = "revoked_at"
    }
}

private struct OpenInvite: Decodable, Sendable {
    let memberID: UUID

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
    }
}

/// `email` is left out unless the parent typed one.
struct ConsentAsk: Encodable, Sendable {
    let memberID: UUID
    let email: String?

    enum CodingKeys: String, CodingKey {
        case email
        case memberID = "memberId"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memberID.uuidString.lowercased(), forKey: .memberID)
        try container.encodeIfPresent(email, forKey: .email)
    }
}

/// Every argument is sent, null included: PostgREST picks the function by its argument names.
private struct DinnerJobParams: Encodable {
    let targetHousehold: UUID
    let job: String
    let isOn: Bool

    enum CodingKeys: String, CodingKey {
        case job
        case targetHousehold = "target_household"
        case isOn = "is_on"
    }
}

private struct DinnerJobPersonParams: Encodable {
    let targetHousehold: UUID
    let targetMember: UUID
    let isIn: Bool

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case targetMember = "target_member"
        case isIn = "is_in"
    }
}

private struct FoodRuleParams: Encodable {
    let targetHousehold: UUID
    let avoid: FoodRule.Avoid
    let nights: FoodRule.Nights?

    enum CodingKeys: String, CodingKey {
        case avoid
        case targetHousehold = "target_household"
        case nights = "on_nights"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetHousehold, forKey: .targetHousehold)
        try container.encode(avoid, forKey: .avoid)
        try container.encode(nights, forKey: .nights)
    }
}
