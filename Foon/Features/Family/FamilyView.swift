import SwiftUI

struct FamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @State private var editor: EditorTarget?
    @State private var confirmingSignOutEverywhere = false

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
            .refreshable { await store.load() }
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
            .sheet(item: $editor) { target in
                switch target {
                case .new: MemberEditorView(member: nil)
                case .existing(let member): MemberEditorView(member: member)
                }
            }
        }
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
        .task { await store.load() }
}
