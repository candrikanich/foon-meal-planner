import SwiftUI

/// Add a member (`member` nil) or edit one. Shows only what the signed-in person may change.
struct MemberEditorView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let member: Member?
    @State private var draft: MemberDraft
    @State private var isSaving = false
    @State private var confirmingRemoval = false
    @State private var inviteCode: String?
    @State private var confirmingWithdrawal = false

    init(member: Member?) {
        self.member = member
        _draft = State(initialValue: member.map(MemberDraft.init) ?? MemberDraft())
    }

    private var scope: HouseholdStore.EditScope {
        member.map(store.editScope(for:)) ?? .everything
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who they are") {
                    TextField("First name", text: $draft.firstName)
                        .disabled(!scope.name)
                    AvatarPicker(selection: $draft.avatar)
                    if scope.identity {
                        Picker("Age", selection: $draft.ageGroup) {
                            Text("Adult").tag(AgeGroup.adult)
                            Text("Kid").tag(AgeGroup.kid)
                        }
                        .pickerStyle(.segmented)
                        if draft.ageGroup == .adult {
                            Toggle("Parent", isOn: $draft.guardian)
                        }
                    }
                }

                if scope.planning {
                    Section {
                        Picker("Planning", selection: $draft.role) {
                            Text("Planner").tag(MemberRole.planner)
                            Text("Member").tag(MemberRole.member)
                        }
                    } footer: {
                        Text("Parents manage the family, allergies, and privacy choices. Planners build the week and manage meals.")
                    }

                    Section("Status") {
                        Picker("Status", selection: $draft.status) {
                            Text("Home").tag(MemberStatus.active)
                            Text("Away").tag(MemberStatus.away)
                        }
                        .pickerStyle(.segmented)
                        if draft.status == .away {
                            Toggle("Return date", isOn: hasReturnDate)
                            if draft.awayUntil != nil {
                                DatePicker("Back on", selection: returnDate, in: Date()..., displayedComponents: .date)
                            }
                        }
                    }
                }

                if scope.schedule {
                    Section {
                        WeekdayAwayPicker(usuallyAway: $draft.usuallyAway)
                    } header: {
                        Text("Usually home for dinner")
                    } footer: {
                        Text("Each new week starts from this. Tap a day they're usually out, like a work or practice night.")
                    }
                }

                if let member, store.canInvite(member) {
                    inviteSection(for: member)
                }

                if let member, store.canWithdrawConsent(member) {
                    Section {
                        Button("Withdraw consent", role: .destructive) {
                            confirmingWithdrawal = true
                        }
                        .disabled(isSaving)
                    } header: {
                        Text("Parental consent")
                    } footer: {
                        Text("\(member.firstName) signs out right away and can rejoin only with your consent and a new invite.")
                    }
                }

                if let member, store.canRemove(member) {
                    Section {
                        Button("Remove from household", role: .destructive) {
                            confirmingRemoval = true
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Their ratings and cooking history stay.")
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(member.map { String(localized: "Edit \($0.firstName)", comment: "Member editor title: first name") } ?? String(localized: "Add member"))
            .onAppear { store.clearError() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(member == nil ? "Add" : "Save") {
                        Task {
                            isSaving = true
                            if await store.save(draft, editing: member?.id) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || draft.validated() == nil)
                }
            }
            .confirmationDialog(
                "Withdraw consent for \(member?.firstName ?? "")?", isPresented: $confirmingWithdrawal, titleVisibility: .visible
            ) {
                Button("Withdraw consent", role: .destructive) {
                    guard let member else { return }
                    Task {
                        isSaving = true
                        if await store.withdrawConsent(member) { dismiss() }
                        isSaving = false
                    }
                }
            } message: {
                Text("They're signed out of the household on their own device now, and stay in the family on yours. If you don't consent again within 30 days, what they added themselves is erased.")
            }
            .confirmationDialog(
                "Remove \(member?.firstName ?? "")?", isPresented: $confirmingRemoval, titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    guard let member else { return }
                    Task {
                        isSaving = true
                        if await store.remove(member) { dismiss() }
                        isSaving = false
                    }
                }
            } message: {
                Text("They lose access right away. Their ratings and history stay.")
            }
        }
    }

    @ViewBuilder
    private func inviteSection(for member: Member) -> some View {
        Section {
            if let inviteCode {
                Text(inviteCode)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Invite code \(inviteCode.map { String($0) }.joined(separator: " "))")
                ShareLink(
                    "Send invite",
                    item: InviteCode.shareMessage(
                        householdName: store.household?.name ?? String(localized: "our family"), firstName: member.firstName, code: inviteCode
                    )
                )
            } else if store.needsParentalConsent(member) {
                Text(ParentalConsent.statement(firstName: member.firstName))
                    .font(.callout)
                Button("Agree and invite \(member.firstName)") {
                    Task {
                        isSaving = true
                        inviteCode = await store.consentAndInvite(member)
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            } else {
                Button(store.invitedMemberIDs.contains(member.id) ? "Invite again" : "Invite \(member.firstName)") {
                    Task {
                        isSaving = true
                        inviteCode = await store.invite(member)
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            }
        } header: {
            Text("Invite")
        } footer: {
            Text(inviteCode == nil
                 ? "Sends a link and a code so \(member.firstName) can join on their own device. Codes work once and expire in 7 days."
                 : "This code is shown only now. Inviting again replaces it.")
        }
    }

    private var hasReturnDate: Binding<Bool> {
        Binding(
            get: { draft.awayUntil != nil },
            set: { draft.awayUntil = $0 ? CalendarDay(Date()) : nil }
        )
    }

    private var returnDate: Binding<Date> {
        Binding(
            get: { draft.awayUntil?.date() ?? Date() },
            set: { draft.awayUntil = CalendarDay($0) }
        )
    }
}

#Preview("Add") {
    let store = HouseholdStore.preview()
    MemberEditorView(member: nil)
        .environment(store)
        .task { await store.load() }
}

#Preview("Edit a kid away at camp") {
    let store = HouseholdStore.preview()
    MemberEditorView(member: Member.sampleFamily[3])
        .environment(store)
        .task { await store.load() }
}

#Preview("Owner editing themselves") {
    let store = HouseholdStore.preview()
    MemberEditorView(member: Member.sampleFamily[0])
        .environment(store)
        .task { await store.load() }
}

/// Seven day chips; a filled chip means home for dinner that weekday.
struct WeekdayAwayPicker: View {
    @Binding var usuallyAway: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WeekMath.weekdays) { weekday in
                let home = !usuallyAway.contains(weekday.iso)
                Button {
                    if home { usuallyAway.insert(weekday.iso) } else { usuallyAway.remove(weekday.iso) }
                } label: {
                    Text(weekday.shortName())
                        .font(.foonCaption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(home ? Palette.onPaprika : Palette.ink)
                        .background(Capsule().fill(home ? Palette.herb : Palette.cardSurface))
                        .overlay(Capsule().strokeBorder(.quaternary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekday.name())
                .accessibilityValue(home ? String(localized: "Home") : String(localized: "Out"))
                .accessibilityAddTraits(.isToggle)
                .accessibilityHint(String(localized: "Toggles whether they're usually home this day"))
            }
        }
        .padding(.vertical, 4)
    }
}
