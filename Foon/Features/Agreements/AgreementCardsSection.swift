import SwiftUI

/// What's waiting on the signed-in person after a wording changed (#277), at the top of Family. Nothing shows while no
/// new wording is in force.
struct AgreementCardsSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library

    private var hasOwnAllergies: Bool {
        guard let me = store.me else { return false }
        return library.allergies.contains { $0.memberID == me.id }
    }

    var body: some View {
        ForEach(store.agreementCards(hasOwnAllergies: hasOwnAllergies)) { prompt in
            AgreementCard(prompt: prompt)
        }
    }
}

private struct AgreementCard: View {
    @Environment(HouseholdStore.self) private var store
    let prompt: AgreementPrompt
    @State private var reviewing = false

    var body: some View {
        switch prompt {
        case .allergyAgreement(let summary):
            Section {
                Text("Foon updated what parents agree to for allergies").font(.headline)
                if let summary { Text(summary) }
                Text("Until a parent agrees, nobody can add allergies. The ones already here still flag dishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Review") { reviewing = true }
                    .accessibilityHint("Shows the new allergy wording to agree to")
            }
            .sheet(isPresented: $reviewing) { AllergyAgreementView(summary: summary, canAgree: true) }
        case .allergyWaitingOnParent(let summary):
            Section {
                Text("A parent needs to agree to Foon's new allergy wording").font(.headline)
                Text("Until one does, nobody can add allergies. The ones already here still flag dishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Read it") { reviewing = true }
            }
            .sheet(isPresented: $reviewing) { AllergyAgreementView(summary: summary, canAgree: false) }
        case .ownAllergies(let summary):
            if let me = store.me {
                Section {
                    Text("Keep your allergies in Foon?").font(.headline)
                    Text("A parent agreed for the family. Foon now asks you too, for your own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Review") { reviewing = true }
                        .accessibilityHint("Shows what you agree to for your own allergies")
                }
                .sheet(isPresented: $reviewing) { OwnAllergiesAgreementView(memberID: me.id, summary: summary) }
            }
        case .updateFoon:
            Section {
                Label("Update Foon to review the new wording.", systemImage: "arrow.down.app")
            } footer: {
                Text("Foon changed what it asks you to agree to, and this version can't show it.")
            }
        case .kidHeld(let hold):
            if let kid = store.members.first(where: { $0.id == hold.memberID }) {
                Section {
                    ParentalConsentRows(member: kid, renewal: hold)
                } header: {
                    Text("\(hold.firstName) needs a parent's OK")
                }
                // Picks up a request another parent, or the renewal email, already started.
                .task(id: kid.id) { await store.loadConsentRequests() }
            }
        }
    }
}

#Preview("A parent, with a kid held and new allergy wording") {
    var client = HouseholdClient.preview()
    client.agreements = { _ in .previewHeld }
    let store = HouseholdStore(userID: .previewUser, client: client)
    return NavigationStack { List { AgreementCardsSection() } }
        .environment(store)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .task { await store.load() }
}

#Preview("Grace, not a parent") {
    let family = Member.sampleFamilySignedInAsGrace
    let grace = family[2]
    var client = HouseholdClient.preview(members: family)
    client.agreements = { _ in .previewHeld }
    var library = LibraryClient.preview()
    library.allergies = { _ in [AllergyRow(memberID: grace.id, allergen: .peanuts, customText: nil)] }
    let libraryStore = LibraryStore(householdID: Household.sample.id, client: library)
    let store = HouseholdStore(userID: .previewGrace, client: client)
    return NavigationStack { List { AgreementCardsSection() } }
        .environment(store)
        .environment(libraryStore)
        .task {
            await store.load()
            await libraryStore.load(members: store.members)
        }
}

#Preview("Nothing in force") {
    let store = HouseholdStore.preview()
    NavigationStack { List { AgreementCardsSection(); Text(verbatim: "Family…") } }
        .environment(store)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .task { await store.load() }
}
