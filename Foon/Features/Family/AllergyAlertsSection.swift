import SwiftUI

/// Family → Allergy alerts, for parents in a family that has turned them on. Off erases every allergy the household
/// has, after a confirmation; on asks for onboarding's one consent sentence again. Family loads the model, since a
/// section that shows nothing never appears to load itself.
struct AllergyAlertsSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    let model: AllergyAlertsModel
    @State private var confirmingOff = false
    @State private var consenting = false

    var body: some View {
        if model.isShown {
            Section {
                Toggle("Allergy alerts", isOn: Binding(
                    get: { model.phase == .ready(.on) },
                    set: { isOn in
                        model.clearError()
                        if isOn { consenting = true } else { confirmingOff = true }
                    }
                ))
                .disabled(model.isSaving)
            } footer: {
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                } else if model.phase == .ready(.on) {
                    Text(
                        "Foon flags dishes with your family's allergies. It's a helper, not a guarantee: still check labels."
                    )
                } else {
                    Text("Off: Foon keeps no allergies for your household. Turn this on to add them again.")
                }
            }
            .confirmationDialog("Turn off allergy alerts?", isPresented: $confirmingOff, titleVisibility: .visible) {
                Button("Turn off and erase allergies", role: .destructive) {
                    Task {
                        guard await model.turnOff() else { return }
                        await library.allergiesErased(members: store.members)
                    }
                }
            } message: {
                Text("It erases every allergy recorded for your household, for everyone. This can't be undone.")
            }
            .sheet(isPresented: $consenting, onDismiss: model.clearError) { AllergyAlertsConsentView(model: model) }
        }
    }
}

/// Turning allergy alerts back on: the same sentence and Agree and save as onboarding. Allergies are added
/// afterwards, on each person's profile.
private struct AllergyAlertsConsentView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AllergyAlertsModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AllergyConsent.statement)
                } footer: {
                    Text("Then add allergies on each person's profile in Family.")
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Allergy alerts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree and save") {
                        Task {
                            if await model.turnOn() { dismiss() }
                        }
                    }
                    .disabled(model.isSaving)
                }
            }
        }
    }
}

#Preview("On") {
    let store = HouseholdStore.preview()
    let model = AllergyAlertsModel(householdID: Household.sample.id, client: .preview())
    List {
        AllergyAlertsSection(model: model)
    }
    .environment(store)
    .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
    .task {
        await store.load()
        await model.load()
    }
}

#Preview("Turning back on") {
    AllergyAlertsConsentView(model: AllergyAlertsModel(householdID: Household.sample.id, client: .preview()))
}
