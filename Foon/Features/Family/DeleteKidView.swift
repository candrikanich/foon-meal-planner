import SwiftUI

/// A parent's "Delete everything about <name>" for a kid (COPPA 312.6, #278): the profile, what Foon keeps about
/// them, and their sign-in account go at once. The family's plans, dishes, dinners and lists stay (docs/spec.md →
/// Privacy).
struct DeleteKidView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let member: Member
    /// Called once they're gone: the editor behind closes, and this sheet with it.
    let onDeleted: () -> Void
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Their profile, allergies, and schedule", systemImage: "person.crop.circle")
                    Label("Their ratings, comments, and thank-yous", systemImage: "star")
                    Label("Their requests, votes, serving notes, and offers to cook", systemImage: "text.bubble")
                    Label("Reminders sent to them, and the record of your consent", systemImage: "bell")
                    if member.userID != nil {
                        Label("Their sign-in account, which signs them out", systemImage: "iphone.slash")
                    }
                } header: {
                    Text("What's deleted")
                } footer: {
                    Text("It all goes now, not after 30 days. This can't be undone.")
                }
                Section {
                    Text("Plans, dishes, dinners, and shopping lists stay, without \(member.firstName)'s name.")
                    Text("Things they added to a list stay on it.")
                } header: {
                    Text("What stays")
                }
                Section {
                    Button("Delete everything about \(member.firstName)", role: .destructive) {
                        Task {
                            isDeleting = true
                            defer { isDeleting = false }
                            if await store.deleteKid(member) { onDeleted() }
                        }
                    }
                    .disabled(isDeleting)
                    if isDeleting {
                        ProgressView("Deleting…")
                    }
                } footer: {
                    if let message = store.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Delete \(member.firstName)?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
            .onAppear { store.clearError() }
        }
    }
}

#Preview("A kid with their own account") {
    let store = HouseholdStore.preview()
    DeleteKidView(member: .fixture(firstName: "Nora", ageGroup: .kid, userID: UUID()), onDeleted: {})
        .environment(store)
        .task { await store.load() }
}

#Preview("A kid without one") {
    let store = HouseholdStore.preview()
    DeleteKidView(member: .fixture(firstName: "Theo", ageGroup: .kid), onDeleted: {})
        .environment(store)
        .task { await store.load() }
}
