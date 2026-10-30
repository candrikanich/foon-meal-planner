import Foundation
import Observation

@Observable @MainActor
final class HouseholdStore {
    enum Phase: Equatable {
        case loading
        case needsHousehold
        case ready(Household)
        case failed
    }

    /// What the signed-in person may change on a member's profile. Mirrors the database rules
    /// (`members_guard_write`) so the UI never offers a change the server will refuse.
    enum EditScope: Equatable {
        /// A parent editing someone else: everything, including removal.
        case everything
        /// The owner editing themselves: not age or parent, which must stay adult and parent.
        case ownProfileAsOwner
        /// Another parent editing the owner's profile: name and avatar only.
        case nameAndAvatar
        /// Anyone else editing themselves.
        case avatarOnly
        case none

        var name: Bool { [.everything, .ownProfileAsOwner, .nameAndAvatar].contains(self) }
        var identity: Bool { self == .everything }
        var planning: Bool { [.everything, .ownProfileAsOwner].contains(self) }
        /// Everyone edits their own usual schedule; parents can change anyone's.
        var schedule: Bool { self != .none }
    }

    private(set) var phase: Phase = .loading
    private(set) var members: [Member] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    /// Profiles with an open invite, shown as "Invite sent".
    private(set) var invitedMemberIDs: Set<UUID> = []
    /// Kids whose parental consent is active (#12).
    private(set) var parentalConsentMemberIDs: Set<UUID> = []
    /// Saved schedules ("School year"), by name; loaded when their screen opens.
    private(set) var attendanceTemplates: [AttendanceTemplate] = []

    let userID: UUID
    let client: HouseholdClient

    init(userID: UUID, client: HouseholdClient) {
        self.userID = userID
        self.client = client
    }

    var household: Household? {
        if case .ready(let household) = phase { household } else { nil }
    }

    var me: Member? {
        members.first { $0.userID == userID }
    }

    /// Guardians (parents) manage people; the owner counts even before their profile loads.
    var canManagePeople: Bool {
        household?.owner == userID || me?.guardian == true
    }

    /// Guardians first, then other adults, then kids; removed members are hidden.
    var visibleMembers: [Member] {
        members.enumerated()
            .filter { $0.element.status != .removed }
            .sorted { lhs, rhs in
                let left = (lhs.element.guardian ? 0 : 1, lhs.element.ageGroup == .adult ? 0 : 1, lhs.offset)
                let right = (rhs.element.guardian ? 0 : 1, rhs.element.ageGroup == .adult ? 0 : 1, rhs.offset)
                return left < right
            }
            .map(\.element)
    }

    func editScope(for member: Member) -> EditScope {
        let isSelf = member.userID == userID
        guard canManagePeople else { return isSelf ? .avatarOnly : .none }
        guard isOwnerProfile(member) else { return .everything }
        return isSelf ? .ownProfileAsOwner : .nameAndAvatar
    }

    /// Planners export the household's data; the owner counts even before their profile loads.
    var canExport: Bool {
        household?.owner == userID || me?.role == .planner
    }

    /// The household's data as a pretty-printed JSON file in the temporary folder, ready to share or save.
    func exportFile() async -> URL? {
        guard let household else { return nil }
        do {
            let raw = try await client.exportHousehold(household.id)
            let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: raw),
                                                    options: [.prettyPrinted, .sortedKeys])
            let name = household.name.replacing(/[\/:]/, with: "-")
            let day = Date.now.formatted(.iso8601.year().month().day())
            let url = URL.temporaryDirectory.appending(path: "Foon - \(name) \(day).json")
            try pretty.write(to: url, options: .atomic)
            errorMessage = nil
            return url
        } catch {
            errorMessage = String(localized: "Couldn't export your household. Check your connection and try again.")
            return nil
        }
    }

    /// The owner erases the household for everyone and keeps their account; this device then has no household, so
    /// the gate shows Create and clears the offline cache. Returns whether it was deleted.
    func deleteHousehold() async -> Bool {
        errorMessage = nil
        do {
            try await client.deleteHousehold()
        } catch HouseholdDeletionError.notOwner {
            await load()
            errorMessage = String(localized: "This household is already deleted, or you're not its owner any more.")
            return false
        } catch {
            errorMessage = String(localized: "Deleting the household didn't finish. Check your connection and try again.")
            return false
        }
        // The server erased it: go straight to start or join, whether or not a reload would get through right now.
        members = []
        invitedMemberIDs = []
        parentalConsentMemberIDs = []
        attendanceTemplates = []
        phase = .needsHousehold
        return true
    }

    /// A sample family nobody else has joined: deleting it needs no typed name. Once another person has their own
    /// account in it, it's their household too, and it's deleted like any other.
    var isUnsharedSample: Bool {
        guard let household, household.planningSettings.isSample else { return false }
        return !members.contains { $0.userID != nil && $0.userID != userID && $0.status != .removed }
    }

    /// Nobody removes the owner (transfer ownership first) or themselves from inside the app.
    func canRemove(_ member: Member) -> Bool {
        canManagePeople && !isOwnerProfile(member) && member.userID != userID
    }

    func clearError() {
        errorMessage = nil
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            guard let household = try await client.myHousehold() else {
                phase = .needsHousehold
                return
            }
            members = try await client.members(household.id)
            invitedMemberIDs = (try? await client.invitedMemberIDs(household.id)) ?? []
            parentalConsentMemberIDs = (try? await client.parentalConsentMemberIDs(household.id)) ?? []
            phase = .ready(household)
        } catch {
            // A view going away cancels its load; that isn't a failure to show.
            guard !Task.isCancelled else { return }
            if household == nil { phase = .failed }
            errorMessage = String(localized: "Couldn't load your household. Check your connection and try again.")
        }
    }

    /// The owner's first-run setup is still to do (or was interrupted): show onboarding.
    var needsOnboarding: Bool {
        guard let household else { return false }
        return household.owner == userID && !household.planningSettings.onboarded
    }

    /// Saves the household's settings (merged on the server). Returns whether it saved.
    @discardableResult
    func updateSettings(_ settings: HouseholdSettings) async -> Bool {
        guard var household else { return false }
        do {
            try await client.updateSettings(household.id, settings)
            household.settings = settings
            phase = .ready(household)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the settings. Check your connection and try again.")
            return false
        }
    }

    // MARK: - Away dates and saved schedules

    /// Adds a stretch to the household's away dates. Returns whether it saved.
    func addAwayDates(_ new: AwayDates, today: CalendarDay) async -> Bool {
        guard let household else { return false }
        return await saveAwayDates(AwayDates.adding(new, to: household.planningSettings.awayDates, today: today))
    }

    /// Ends a stretch: its nights from today on go back to usual schedules. Returns whether it saved.
    func removeAwayDates(_ dates: AwayDates) async -> Bool {
        guard let household else { return false }
        return await saveAwayDates(household.planningSettings.awayDates.filter { $0 != dates })
    }

    private func saveAwayDates(_ dates: [AwayDates]) async -> Bool {
        guard var household else { return false }
        do {
            try await client.setAwayDates(household.id, dates)
            var settings = household.planningSettings
            settings.awayDates = dates
            household.settings = settings
            phase = .ready(household)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the away dates. Check your connection and try again.")
            return false
        }
    }

    func loadTemplates() async {
        guard let household else { return }
        do {
            attendanceTemplates = try await client.attendanceTemplates(household.id)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "Couldn't load your saved schedules. Check your connection and try again.")
        }
    }

    /// Saves everyone's usual schedule under a name, replacing one that has it already. Returns whether it saved.
    func saveTemplate(named raw: String) async -> Bool {
        guard let household else { return false }
        guard let name = AttendanceTemplate.validatedName(raw) else {
            errorMessage = String(localized: "Schedule names need 1 to 40 characters.")
            return false
        }
        do {
            let saved = try await client.saveAttendanceTemplate(household.id, name)
            attendanceTemplates = (attendanceTemplates.filter { $0.id != saved.id } + [saved])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the schedule. Check your connection and try again.")
            return false
        }
    }

    /// Makes a saved schedule everyone's usual one, for weeks started from now on. Returns whether it worked.
    func applyTemplate(_ template: AttendanceTemplate) async -> Bool {
        guard let household else { return false }
        do {
            try await client.applyAttendanceTemplate(template.id)
            members = try await client.members(household.id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't switch schedules. Pull to refresh, then try again.")
            return false
        }
    }

    func deleteTemplate(_ template: AttendanceTemplate) async -> Bool {
        do {
            try await client.deleteAttendanceTemplate(template.id)
            attendanceTemplates = attendanceTemplates.filter { $0.id != template.id }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't delete the schedule. Check your connection and try again.")
            return false
        }
    }

    /// Onboarding's last step: the rhythm is saved and the household is set up.
    func finishOnboarding(_ settings: HouseholdSettings) async -> Bool {
        var done = settings
        done.onboarded = true
        done.samplePending = false
        return await updateSettings(done)
    }

    func createHousehold(name: String, emoji: String?, firstName: String, sample: Bool = false) async {
        errorMessage = nil
        var owner = MemberDraft()
        owner.firstName = firstName
        guard let name = Household.validatedName(name), let owner = owner.validated() else {
            errorMessage = String(localized: "Add a household name and your first name.")
            return
        }
        let emoji = emoji?.trimmingCharacters(in: .whitespaces)
        var fresh = HouseholdSettings()
        fresh.onboarded = false
        fresh.samplePending = sample
        fresh.isSample = sample
        fresh.timeZone = TimeZone.current.identifier
        var household: Household
        do {
            household = try await client.createHousehold(name, emoji?.isEmpty == false ? emoji : nil,
                                                         owner.firstName, fresh)
        } catch {
            errorMessage = String(localized: "Couldn't create your household. Check your connection and try again.")
            return
        }
        household.settings = household.settings ?? fresh
        // The household exists now; a members hiccup must not send the user back to create it again.
        phase = .ready(household)
        do {
            members = try await client.members(household.id)
        } catch {
            errorMessage = String(localized: "Your household is ready. Pull to refresh to see your family.")
        }
    }

    /// Adds a member (`editing` nil) or saves changes to one. Returns whether it saved.
    func save(_ draft: MemberDraft, editing memberID: UUID?) async -> Bool {
        errorMessage = nil
        guard let household else { return false }
        guard let draft = draft.validated() else {
            errorMessage = String(localized: "First names need 1 to 30 characters.")
            return false
        }
        do {
            if let memberID {
                guard let original = members.first(where: { $0.id == memberID }) else { return false }
                let changes = draft.changes(from: original)
                guard !changes.isEmpty else { return true }
                let saved = try await client.updateMember(memberID, changes)
                members = members.map { $0.id == memberID ? saved : $0 }
            } else {
                members.append(try await client.addMember(household.id, draft))
            }
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save. Pull to refresh in case someone else changed this, then try again.")
            return false
        }
    }

    /// Removal keeps the profile's history and unlinks their account.
    func remove(_ member: Member) async -> Bool {
        var draft = MemberDraft(member)
        draft.status = .removed
        return await save(draft, editing: member.id)
    }

    /// Parents invite profiles nobody has claimed yet.
    func canInvite(_ member: Member) -> Bool {
        canManagePeople && member.userID == nil && member.status != .removed
    }

    /// Creates an invite and returns the code to share, or nil with a message.
    func invite(_ member: Member) async -> String? {
        errorMessage = nil
        do {
            let code = try await client.createInvite(member.id)
            invitedMemberIDs.insert(member.id)
            return code
        } catch {
            errorMessage = String(localized: "Couldn't create an invite. Check your connection and try again.")
            return nil
        }
    }

    /// A kid's invite needs a parent's recorded consent first (COPPA, #12).
    func needsParentalConsent(_ member: Member) -> Bool {
        member.ageGroup == .kid && !parentalConsentMemberIDs.contains(member.id)
    }

    /// Records the parent's consent, then creates the invite. Returns the code, or nil with a message.
    func consentAndInvite(_ member: Member) async -> String? {
        errorMessage = nil
        guard let household else { return nil }
        if needsParentalConsent(member) {
            do {
                try await client.recordParentalConsent(household.id, member.id)
                parentalConsentMemberIDs.insert(member.id)
            } catch {
                // Consent may already exist (it failed to load earlier); check before giving up.
                parentalConsentMemberIDs = (try? await client.parentalConsentMemberIDs(household.id)) ?? parentalConsentMemberIDs
                guard !needsParentalConsent(member) else {
                    errorMessage = String(localized: "Couldn't record your consent. Check your connection and try again.")
                    return nil
                }
            }
        }
        return await invite(member)
    }

    func canWithdrawConsent(_ member: Member) -> Bool {
        canManagePeople && member.ageGroup == .kid && parentalConsentMemberIDs.contains(member.id)
    }

    /// Withdraws a kid's parental consent: their account is unlinked at once and open invites end;
    /// the profile and its history stay. Returns whether it worked.
    func withdrawConsent(_ member: Member) async -> Bool {
        errorMessage = nil
        do {
            try await client.revokeParentalConsent(member.id)
            parentalConsentMemberIDs.remove(member.id)
            invitedMemberIDs.remove(member.id)
            members = members.map { candidate in
                guard candidate.id == member.id else { return candidate }
                var unlinked = candidate
                unlinked.userID = nil
                return unlinked
            }
            return true
        } catch {
            errorMessage = String(localized: "Couldn't withdraw consent. Check your connection and try again.")
            return false
        }
    }

    /// Joins the household behind an invite code, then loads it.
    func redeem(_ typedCode: String) async {
        errorMessage = nil
        guard InviteCode.isComplete(typedCode) else {
            errorMessage = RedeemResult.invalid.message
            return
        }
        do {
            let result = try await client.redeemInvite(InviteCode.normalized(typedCode))
            guard result == .claimed else {
                errorMessage = result.message
                return
            }
            await load()
        } catch {
            errorMessage = String(localized: "Couldn't check that code. Check your connection and try again.")
        }
    }

    private func isOwnerProfile(_ member: Member) -> Bool {
        member.userID != nil && member.userID == household?.owner
    }
}
