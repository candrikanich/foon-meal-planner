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
    }

    private(set) var phase: Phase = .loading
    private(set) var members: [Member] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    /// Profiles with an open invite, shown as "Invite sent".
    private(set) var invitedMemberIDs: Set<UUID> = []
    /// Kids whose parental consent is active (#12).
    private(set) var parentalConsentMemberIDs: Set<UUID> = []

    let userID: UUID
    private let client: HouseholdClient

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

    func createHousehold(name: String, emoji: String?, firstName: String) async {
        errorMessage = nil
        var owner = MemberDraft()
        owner.firstName = firstName
        guard let name = Household.validatedName(name), let owner = owner.validated() else {
            errorMessage = String(localized: "Add a household name and your first name.")
            return
        }
        let emoji = emoji?.trimmingCharacters(in: .whitespaces)
        let household: Household
        do {
            household = try await client.createHousehold(name, emoji?.isEmpty == false ? emoji : nil, owner.firstName)
        } catch {
            errorMessage = String(localized: "Couldn't create your household. Check your connection and try again.")
            return
        }
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
