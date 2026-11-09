import SwiftUI

/// Terms of Use and Privacy Policy, agreed before an adult uses a household or creates one (#277): "Before you start"
/// the first time, "We updated our terms" when a version they agreed to is replaced. Shown only while both are in
/// force.
struct AgreementsGateView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let gate: TermsGate
    /// Set in the sheet before creating a household: Cancel instead of Sign out, then this once they've agreed.
    var onAgreed: (() -> Void)?
    @State private var actions = AgreementActions()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if gate.firstTime {
                        Text("""
                        Foon's Terms of Use and Privacy Policy say how Foon works and what it keeps about your family. \
                        Read them, then agree to keep going.
                        """)
                    } else {
                        Text("Foon changed its Terms of Use or Privacy Policy. Here's what changed:")
                        ForEach(gate.summaries, id: \.self) { summary in
                            Text(summary).foregroundStyle(.secondary)
                        }
                    }
                    PolicyLinks()
                }
                Section {
                    Button {
                        Task { await agree() }
                    } label: {
                        Text("Agree").frame(maxWidth: .infinity)
                    }
                    .disabled(actions.isSaving)
                    .accessibilityHint("Agrees to the Terms of Use and Privacy Policy")
                } footer: {
                    if let message = actions.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Tapping Agree means you agree to the Terms of Use and Privacy Policy.")
                    }
                }
            }
            .navigationTitle(gate.firstTime ? "Before you start" : "We updated our terms")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if onAgreed == nil {
                        Button("Sign out") { Task { await session.signOut() } }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private func agree() async {
        guard await actions.accept(gate, using: store.client) else { return }
        await store.recordTermsAccepted()
        if let onAgreed {
            dismiss()
            onAgreed()
        }
    }
}

#Preview("Before you start") {
    AgreementsGateView(gate: .previewFirstTime)
        .environment(HouseholdStore.preview())
        .environment(SessionStore(auth: .preview()))
}

#Preview("We updated our terms") {
    AgreementsGateView(gate: .previewChanged)
        .environment(HouseholdStore.preview())
        .environment(SessionStore(auth: .preview()))
}
