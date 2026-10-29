import SwiftUI

/// The owner's Delete household: everything in it goes, for everyone, and every account stays. A real household needs
/// its name typed to confirm; the sample family doesn't (docs/spec.md → Retention).
enum HouseholdDeletion {
    static func confirms(_ typed: String, name: String) -> Bool {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && typed.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

struct DeleteHouseholdView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var isDeleting = false
    @State private var exportURL: URL?

    private var name: String { store.household?.name ?? "" }
    private var isSample: Bool { store.isUnsharedSample }
    private var confirmed: Bool { isSample || HouseholdDeletion.confirms(typed, name: name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isSample {
                        Text("This deletes the sample family and everything in it. You keep your account and go back to start your own household.")
                    } else {
                        Text("This deletes \(name) for everyone: meals, plans, lists, photos, and family profiles. Everyone keeps their account and can start or join another household. This can't be undone.")
                    }
                }
                if !isSample {
                    Section {
                        ExportButton(exportURL: $exportURL)
                    } footer: {
                        Text("Want a copy first? Export saves everything as a file.")
                    }
                    Section {
                        TextField(name, text: $typed)
                            .autocorrectionDisabled()
                            .accessibilityLabel(Text("Type \(name) to confirm"))
                    } header: {
                        Text("Type \(name) to confirm")
                    }
                }
                Section {
                    Button(isSample ? "Delete the sample family" : "Delete household", role: .destructive) {
                        Task {
                            isDeleting = true
                            defer { isDeleting = false }
                            // On success the household is gone and the gate swaps to Create, taking this sheet with it.
                            _ = await store.deleteHousehold()
                        }
                    }
                    .disabled(!confirmed || isDeleting)
                    if isDeleting {
                        ProgressView("Deleting…")
                    }
                } footer: {
                    if let message = store.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isSample ? "Start your real family?" : "Delete household?")
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

#Preview("Real household") {
    let store = HouseholdStore.preview()
    DeleteHouseholdView()
        .environment(store)
        .task { await store.load() }
}
