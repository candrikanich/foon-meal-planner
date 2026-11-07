import SwiftUI

/// Adds or changes one person's allergies, with onboarding's chips and its one consent sentence: a parent for anyone,
/// or an adult who isn't a parent for themselves (#285).
struct MemberAllergiesView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let member: Member
    let ownProfile: Bool
    @State private var model: AllergyEditorModel

    init(member: Member, ownProfile: Bool = false, household: HouseholdClient, library: LibraryClient) {
        self.member = member
        self.ownProfile = ownProfile
        _model = State(initialValue: AllergyEditorModel(memberID: member.id, householdID: member.householdID,
                                                        ownProfile: ownProfile, household: household, library: library))
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
                        if ownProfile {
                            Text("Couldn't load your allergies. Check your connection and try again.")
                        } else {
                            Text("Couldn't load \(member.firstName)'s allergies. Check your connection and try again.")
                        }
                        Button("Try again") { Task { await model.load() } }
                    }
                case .ready:
                    if model.canAdd {
                        if model.showsStatement {
                            Section { Text(AllergyConsent.statement).font(.callout) }
                        }
                        Section {
                            AllergenChips(selection: $model.answer.allergens)
                            TextField("Other (like kiwi)", text: $model.answer.otherText)
                        } footer: {
                            Text("Foon flags dishes with these. It's a helper, not a guarantee: still check labels.")
                        }
                    } else {
                        Section {
                            Text("Foon keeps allergies once a parent agrees. Ask a parent to add yours first.")
                        }
                    }
                    if let message = model.errorMessage {
                        Section { Text(message).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(ownProfile ? "Your allergies" : "\(member.firstName)'s allergies")
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

#Preview("Grace, not a parent, changing her own") {
    let grace = Member.sampleFamily[2]
    let store = HouseholdStore.preview()
    var allergies = LibraryClient.preview()
    allergies.allergies = { _ in [AllergyRow(memberID: grace.id, allergen: .peanuts, customText: nil)] }
    let library = LibraryStore(householdID: Household.sample.id, client: allergies)
    return MemberAllergiesView(member: grace, ownProfile: true, household: .preview(), library: allergies)
        .environment(store)
        .environment(library)
        .task { await store.load() }
}

#Preview("Grace, before a parent agreed to keep allergies") {
    let store = HouseholdStore.preview()
    var household = HouseholdClient.preview()
    household.allergyAlerts = { _ in .neverOn }
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    return MemberAllergiesView(member: Member.sampleFamily[2], ownProfile: true, household: household,
                               library: .preview())
        .environment(store)
        .environment(library)
        .task { await store.load() }
}
