import SwiftUI

struct FamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @State private var editor: EditorTarget?

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
        let age = member.ageGroup == .adult ? "Adult" : "Kid"
        let role = member.role == .planner ? "Planner" : "Member"
        return ([age, role, status] + (invited ? ["Invite sent"] : [])).joined(separator: " · ")
    }

    private var status: String {
        guard member.status == .away else { return "Home" }
        guard let day = member.awayUntil else { return "Away" }
        return "Away until \(day.date().formatted(.dateTime.month(.abbreviated).day()))"
    }
}

#Preview("Parent") {
    let store = HouseholdStore.preview()
    FamilyView()
        .environment(store)
        .environment(SessionStore(auth: .preview()))
        .task { await store.load() }
}
