import SwiftUI

struct FamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(DinnerStore.self) private var dinner
    @State private var editor: EditorTarget?
    @State private var confirmingSignOutEverywhere = false
    @State private var deletingAccount = false
    @State private var deletingHousehold = false
    @State private var exportURL: URL?

    private var isOwner: Bool { store.household?.owner == store.userID }

    private var accountDeletion: AccountDeletion {
        .outcome(household: store.household, me: store.me, userID: store.userID)
    }

    var body: some View {
        NavigationStack {
            List {
                if let household = store.household {
                    Section {
                        HStack(spacing: 12) {
                            Text(household.emoji ?? "🏡").font(.largeTitle).accessibilityHidden(true)
                            Text(household.name).font(.title2.bold())
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if isOwner, store.isUnsharedSample {
                        Section {
                            Button("Start your real family", systemImage: "house") { deletingHousehold = true }
                        } footer: {
                            Text("This is the sample family. Delete it and set up your own; you keep your account.")
                        }
                    }
                }

                Section("Family") {
                    ForEach(store.visibleMembers) { member in
                        if store.editScope(for: member) == .none {
                            MemberRow(member: member, isYou: false, invited: store.invitedMemberIDs.contains(member.id))
                        } else {
                            Button {
                                editor = .existing(member)
                            } label: {
                                MemberRow(member: member, isYou: member.userID == store.userID,
                                          invited: store.invitedMemberIDs.contains(member.id))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Edit")
                        }
                    }
                }


                // Family order, not a ranking: credit, not a leaderboard.
                let cooks = Dictionary(dinner.cookTally.map { ($0.memberID, $0) }, uniquingKeysWith: { first, _ in first })
                let cooking = store.visibleMembers.filter { cooks[$0.id] != nil }
                if !cooking.isEmpty {
                    Section {
                        ForEach(cooking) { member in
                            if let tally = cooks[member.id] {
                                HStack(spacing: 12) {
                                    MemberAvatar(member: member)
                                    Text(member.firstName).font(.body.weight(.medium))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(tally.dinners == 1 ? String(localized: "1 dinner")
                                                                : String(localized: "\(tally.dinners) dinners"))
                                        if tally.thanks > 0 {
                                            Text(tally.thanks == 1 ? String(localized: "1 thank-you")
                                                                   : String(localized: "\(tally.thanks) thank-yous"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    } header: {
                        Text("Cooked this month")
                    } footer: {
                        Text("From the dinners logged after each meal. Tap Thanks, chef on This Week to say so.")
                    }
                }
                Section {
                    if store.canExport {
                        ExportButton(exportURL: $exportURL)
                    }
                    if isOwner {
                        Button("Delete household", role: .destructive) { deletingHousehold = true }
                    }
                    Button(accountDeletion.buttonTitle, role: .destructive) { deletingAccount = true }
                } header: {
                    Text("Your data")
                } footer: {
                    if let message = store.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else if isOwner {
                        Text("Delete household erases it for everyone and keeps your account. Deleting your account also deletes the household. Neither can be undone.")
                    } else if store.canExport {
                        Text("Export saves the household's meals, plans, lists, and family as a file. Deleting your account can't be undone.")
                    } else {
                        Text("Deleting your account can't be undone.")
                    }
                }

                Section {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                    Button("Sign out of all devices", role: .destructive) {
                        confirmingSignOutEverywhere = true
                    }
                } footer: {
                    if let message = session.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Use this if a phone is lost or shared. Every device, this one included, signs out right away.")
                    }
                }
            }
            .refreshable {
                await store.load()
                await loadDinners()
            }
            // Waits for the household, so the tally uses its time zone (the store's calendar is shared with This Week).
            .task(id: store.household?.id) { await loadDinners() }
            .navigationTitle("Family")
            .toolbar {
                if store.canManagePeople {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add member", systemImage: "person.badge.plus") {
                            editor = .new
                        }
                    }
                }
            }
            .confirmationDialog(
                "Sign out of all devices?", isPresented: $confirmingSignOutEverywhere, titleVisibility: .visible
            ) {
                Button("Sign out everywhere", role: .destructive) {
                    Task { _ = await session.signOutEverywhere() }
                }
            } message: {
                Text("Foon signs out on every phone, tablet, and Mac using your account, including this one.")
            }
            .sheet(isPresented: $deletingAccount) { DeleteAccountView() }
            .sheet(isPresented: $deletingHousehold) { DeleteHouseholdView() }
            .sheet(item: $editor) { target in
                switch target {
                case .new: MemberEditorView(member: nil)
                case .existing(let member): MemberEditorView(member: member)
                }
            }
        }
    }

    private func loadDinners() async {
        guard let household = store.household else { return }
        await dinner.load(settings: household.planningSettings)
    }

    private enum EditorTarget: Identifiable {
        case new
        case existing(Member)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let member): member.id.uuidString
            }
        }
    }
}

struct MemberRow: View {
    let member: Member
    let isYou: Bool
    var invited = false

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatar(member: member)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.firstName).font(.body.weight(.medium))
                    if isYou {
                        Text("You").font(.caption).foregroundStyle(.secondary)
                    }
                    if member.guardian {
                        Text("Parent")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.15)))
                    }
                }
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let age = member.ageGroup == .adult ? String(localized: "Adult") : String(localized: "Kid")
        let role = member.role == .planner ? String(localized: "Planner") : String(localized: "Member")
        return ([age, role, status] + (invited ? [String(localized: "Invite sent")] : [])).joined(separator: " · ")
    }

    private var status: String {
        guard member.status == .away else { return String(localized: "Home") }
        guard let day = member.awayUntil else { return String(localized: "Away") }
        let date = day.date().formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "Away until \(date)", comment: "Member status: a short date such as Nov 4")
    }
}

#Preview("Parent") {
    let store = HouseholdStore.preview()
    FamilyView()
        .environment(store)
        .environment(SessionStore(auth: .preview()))
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .task { await store.load() }
}
