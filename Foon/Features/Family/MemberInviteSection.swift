import SwiftUI

/// Member detail's Invite and Parental consent sections, for a parent. They sit on the profile itself, not behind Edit,
/// so "open Family, then the kid, then Invite" (or Withdraw consent) in the consent emails and pages is the real path.
struct MemberInviteSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let member: Member
    @State private var inviteCode: String?
    @State private var isWorking = false
    @State private var confirmingWithdrawal = false
    /// What went wrong with the last invite or withdrawal. The store's message is shared, so it's copied here only when
    /// one of these fails.
    @State private var inviteFailure: String?
    @State private var withdrawFailure: String?

    var body: some View {
        // Group would copy its modifiers onto each child, so each section carries only its own: one reload, one dialog.
        if store.canInvite(member) {
            inviteSection
                // A parent agrees, or withdraws with email 2's link, outside Foon: look again on opening and on return.
                .task(id: member.id) { await reloadConsent() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await reloadConsent() } }
                }
        }
        if store.canWithdrawConsent(member) {
            withdrawSection
                .confirmationDialog(
                    "Withdraw consent for \(member.firstName)?", isPresented: $confirmingWithdrawal,
                    titleVisibility: .visible
                ) {
                    Button("Withdraw consent", role: .destructive) {
                        Task {
                            isWorking = true
                            inviteCode = nil
                            withdrawFailure = await store.withdrawConsent(member) ? nil : store.errorMessage
                            isWorking = false
                        }
                    }
                } message: {
                    Text("They're signed out of the household on their own device now, and stay in the family on yours. If you don't consent again within 30 days, what they added themselves is erased.")
                }
        }
    }

    private func reloadConsent() async {
        guard member.ageGroup == .kid, store.canInvite(member) else { return }
        await store.loadConsentRequests()
    }

    private var inviteSection: some View {
        Section {
            if let inviteCode {
                Text(inviteCode)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Invite code \(inviteCode.map { String($0) }.joined(separator: " "))")
                ShareLink(
                    "Send invite",
                    item: InviteCode.shareMessage(
                        householdName: store.household?.name ?? String(localized: "our family"),
                        firstName: member.firstName, code: inviteCode
                    )
                )
            } else if store.needsParentalConsent(member) {
                ParentalConsentRows(member: member, renewal: store.kidHold(for: member))
            } else {
                Button(store.invitedMemberIDs.contains(member.id) ? "Invite again" : "Invite \(member.firstName)") {
                    Task {
                        isWorking = true
                        inviteCode = await store.invite(member)
                        inviteFailure = inviteCode == nil ? store.errorMessage : nil
                        isWorking = false
                    }
                }
                .disabled(isWorking)
            }
            if let inviteFailure {
                Text(inviteFailure).font(.callout).foregroundStyle(.red)
            }
        } header: {
            if store.kidHold(for: member) != nil {
                Text("Needs a parent's OK again")
            } else {
                Text("Invite")
            }
        } footer: {
            if inviteCode != nil {
                Text("This code is shown only now. Inviting again replaces it.")
            } else if !store.needsParentalConsent(member) {
                Text("Sends a link and a code so \(member.firstName) can join on their own device. Codes work once and expire in 7 days.")
            }
        }
    }

    private var withdrawSection: some View {
        Section {
            Button("Withdraw consent", role: .destructive) {
                confirmingWithdrawal = true
            }
            .disabled(isWorking)
            if let withdrawFailure {
                Text(withdrawFailure).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Parental consent")
        } footer: {
            Text("\(member.firstName) signs out right away and can rejoin only with your consent and a new invite.")
        }
    }
}

#Preview("Invite an adult") {
    let store = HouseholdStore(userID: .previewUser, client: .preview())
    return NavigationStack {
        List { MemberInviteSection(member: Member.sampleFamily[1]) }
    }
    .environment(store)
    .task { await store.load() }
}
