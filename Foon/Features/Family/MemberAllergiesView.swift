import SwiftUI

/// A parent adds or changes one person's allergies, with onboarding's chips and its one consent sentence.
struct MemberAllergiesView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let member: Member
    @State private var model: AllergyEditorModel

    init(member: Member, household: HouseholdClient, library: LibraryClient) {
        self.member = member
        _model = State(initialValue: AllergyEditorModel(memberID: member.id, householdID: member.householdID,
                                                        household: household, library: library))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                switch model.phase {
                case .loading:
                    ProgressView()
                case .failed:
                    Section {
                        Text("Couldn't load \(member.firstName)'s allergies. Check your connection and try again.")
                        Button("Try again") { Task { await model.load() } }
                    }
                case .ready:
                    if model.needsConsent {
                        Section { Text(AllergyConsent.statement).font(.callout) }
                    }
                    Section {
                        AllergenChips(selection: $model.answer.allergens)
                        TextField("Other (like kiwi)", text: $model.answer.otherText)
                    } footer: {
                        Text("Foon flags dishes with these. It's a helper, not a guarantee: still check labels.")
                    }
                    if let message = model.errorMessage {
                        Section { Text(message).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("\(member.firstName)'s allergies")
            .task { await model.load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.needsConsent ? "Agree and save" : "Save") {
                        Task {
                            guard let saved = await model.save() else { return }
                            dismiss()
                            await library.showAllergies(saved, for: member, members: store.members)
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
    }
}

#Preview("Nora, who can't have milk") {
    let store = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    MemberAllergiesView(member: Member.sampleFamily[4], household: .preview(), library: .preview())
        .environment(store)
        .environment(library)
        .task { await store.load() }
}
