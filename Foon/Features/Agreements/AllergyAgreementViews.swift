import SwiftUI

/// The household's allergy wording after it changed (#277). A parent reviews it and agrees for the household; any other
/// adult reads it, since only a parent agrees. Until one does, nobody adds allergies and the ones there still flag.
struct AllergyAgreementView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let summary: String?
    let canAgree: Bool
    @State private var actions = AgreementActions()

    var body: some View {
        NavigationStack {
            Form {
                if let summary {
                    Section("What changed") { Text(summary) }
                }
                Section {
                    Text(AllergyConsent.statement)
                    HealthDataPolicyLink()
                } header: {
                    Text("What a parent agrees to")
                } footer: {
                    if canAgree {
                        Text("You agree for your household. A parent can withdraw anytime in Family → Allergy alerts.")
                    } else {
                        Text("""
                        Only a parent agrees for the household. Until one does, nobody can add allergies, and the ones \
                        already here still flag dishes.
                        """)
                    }
                }
                if let message = actions.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Allergy wording")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(canAgree ? "Cancel" : "Done") { dismiss() }
                }
                if canAgree {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Agree") { Task { await agree() } }
                            .disabled(actions.isSaving)
                            .accessibilityHint("Agrees, for your household, to keep allergies with this wording")
                    }
                }
            }
        }
    }

    private func agree() async {
        guard let household = store.household,
              await actions.agreeForHousehold(household.id, using: store.client) else { return }
        await store.reloadAgreements()
        dismiss()
    }
}

/// "Keep your allergies in Foon?" for an adult who isn't a parent, once their own say is asked for (#277). Saying
/// nothing keeps their allergies flagging dishes; they just can't add new ones until they agree.
struct OwnAllergiesAgreementView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let memberID: UUID
    let summary: String?
    /// Runs once they've agreed, after the store has the news.
    var onAgreed: (() async -> Void)?
    @State private var actions = AgreementActions()

    var body: some View {
        NavigationStack {
            Form {
                if let summary {
                    Section { Text(summary) }
                }
                Section {
                    Text(OwnAllergyConsent.statement)
                    HealthDataPolicyLink()
                } footer: {
                    Text("""
                    If you don't, the allergies on your profile still flag dishes, and you can remove them. You can't \
                    add new ones until you agree.
                    """)
                }
                if let message = actions.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Keep your allergies in Foon?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree") { Task { await agree() } }
                        .disabled(actions.isSaving)
                        .accessibilityHint("Agrees to keep your own allergies in Foon")
                }
            }
        }
    }

    private func agree() async {
        guard await actions.agreeForMyself(memberID, using: store.client) else { return }
        await store.reloadAgreements()
        await onAgreed?()
        dismiss()
    }
}

#Preview("A parent reviews") {
    let store = HouseholdStore.preview()
    AllergyAgreementView(summary: AgreementStatus.Allergy.previewSummary, canAgree: true)
        .environment(store)
        .task { await store.load() }
}

#Preview("Another adult reads it") {
    AllergyAgreementView(summary: AgreementStatus.Allergy.previewSummary, canAgree: false)
        .environment(HouseholdStore.preview())
}

#Preview("Keep your allergies?") {
    OwnAllergiesAgreementView(memberID: Member.sampleFamily[2].id, summary: AgreementStatus.Allergy.previewOwnSummary)
        .environment(HouseholdStore.preview())
}
