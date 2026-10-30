import SwiftUI

/// Who someone is, at a glance (docs/spec.md → Family tab). Everyone in the household sees it; what they can change is in
/// the editor, and allergies are a parent's. Looks the member up each time, so an edit shows as soon as it's saved.
struct MemberDetailView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(DinnerStore.self) private var dinner
    @Environment(\.dismiss) private var dismiss
    let memberID: UUID
    @State private var editing = false

    private var member: Member? {
        store.members.first { $0.id == memberID && $0.status != .removed }
    }

    var body: some View {
        Group {
            if let member {
                content(member)
            } else {
                ContentUnavailableView("No longer in the family", systemImage: "person.slash")
            }
        }
        .navigationTitle(member?.firstName ?? "")
        // Everyone's latest: a parent may have added an allergy since this phone last loaded the library.
        .task { await library.load(members: store.members) }
        .onChange(of: member == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func content(_ member: Member) -> some View {
        List {
            MemberAboutSection(member: member, today: today,
                               invited: store.invitedMemberIDs.contains(member.id), isYou: member.userID == store.userID)
            MemberScheduleSection(member: member, today: today, canEdit: store.editScope(for: member).schedule)
            if library.hasLoaded {
                MemberAllergySection(member: member, allergies: library.allergies.first { $0.memberID == member.id },
                                     canEdit: store.canManagePeople)
                MemberTasteSections(member: member, profile: TasteProfile(
                    memberID: member.id, verdicts: library.reactions.verdicts, notes: library.servingNotes, meals: library.meals
                ))
            } else if library.errorMessage != nil {
                Section {
                    Text("Couldn't load allergies and favorites. Check your connection and try again.")
                    Button("Try again") { Task { await library.load(members: store.members) } }
                }
            } else {
                Section { ProgressView() }
            }
            // No row at zero: this is credit, so nobody's profile says they didn't cook.
            if let tally = dinner.cookTally.first(where: { $0.memberID == member.id }) {
                Section("Cooked this month") {
                    Text(tally.dinnersTitle)
                    if tally.thanks > 0 { Text(tally.thanksTitle) }
                }
            }
        }
        .toolbar {
            if store.editScope(for: member) != .none {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) { MemberEditorView(member: member) }
    }

    private var today: CalendarDay {
        (store.household?.planningSettings ?? HouseholdSettings()).today()
    }
}

private struct MemberAboutSection: View {
    let member: Member
    let today: CalendarDay
    let invited: Bool
    let isYou: Bool

    var body: some View {
        Section {
            HStack(spacing: 12) {
                MemberAvatar(member: member, size: 56)
                Text(member.firstName).font(.title2.bold())
                if isYou { Text("You").font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            LabeledContent("Status", value: member.statusTitle(today: today))
            LabeledContent("Age", value: member.ageTitle)
            if member.guardian { LabeledContent("Family role", value: String(localized: "Parent")) }
            LabeledContent("Planning", value: member.roleTitle)
            if member.eatsSeparately { LabeledContent("Dinner", value: String(localized: "Eats separately")) }
            if invited { LabeledContent("Invite", value: String(localized: "Invite sent")) }
        }
    }
}

private struct MemberScheduleSection: View {
    let member: Member
    let today: CalendarDay
    let canEdit: Bool

    var body: some View {
        Section {
            Text(member.scheduleTitle)
            if let pattern = member.awayPattern {
                Text(pattern.summary)
                if let next = pattern.nextNight(onOrAfter: today) {
                    Text("Next night out: \(DayCardText.dateLabel(for: next))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Usual schedule")
        } footer: {
            Text(canEdit ? "Each new week starts from this. Tap Edit to change it."
                         : "Each new week starts from this. Everyone sets their own, and a parent can change it.")
        }
    }
}

private struct MemberAllergySection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    let member: Member
    let allergies: MemberAllergies?
    let canEdit: Bool
    @State private var editing = false

    var body: some View {
        // A family without allergies never sees this. Parents get the way to add one later.
        if allergies != nil || canEdit {
            Section {
                if let allergies {
                    Text(allergies.displayNames.joined(separator: ", "))
                }
                if canEdit {
                    Button(allergies == nil ? "Add allergies" : "Change allergies") { editing = true }
                        .sheet(isPresented: $editing) {
                            MemberAllergiesView(member: member, household: store.client, library: library.client)
                        }
                }
            } header: {
                Text("Allergies")
            } footer: {
                Text(canEdit ? "Everyone in the family sees these. Foon flags dishes, and you still check labels."
                             : "A parent keeps these up to date. Foon flags dishes, and you still check labels.")
            }
        }
    }
}

/// Dishes, never the cook. Read-only: ratings come from after dinner, and notes from the meal.
private struct MemberTasteSections: View {
    let member: Member
    let profile: TasteProfile

    var body: some View {
        if profile.isEmpty {
            Section("Taste") {
                Text(member.eatsSeparately ? "They eat separately, so they don't rate dinners."
                                           : "Nothing yet. Favorites show up here after dinners get rated.")
                    .foregroundStyle(.secondary)
            }
        }
        if !profile.favorites.isEmpty {
            Section("Favorites") {
                ForEach(profile.favorites) { Text($0.name) }
            }
        }
        if !profile.ratherSkip.isEmpty {
            Section("Would rather skip") {
                ForEach(profile.ratherSkip) { Text($0.name) }
            }
        }
        if !profile.notes.isEmpty {
            Section("How they like it served") {
                ForEach(profile.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.dish)
                        Text(note.note).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct MemberDetailPreview: View {
    var store = HouseholdStore.preview()
    var library = LibraryStore(householdID: Household.sample.id, client: .preview())
    var dinner = DinnerStore(householdID: Household.sample.id, client: .preview)
    let member: Member

    var body: some View {
        NavigationStack { MemberDetailView(memberID: member.id) }
            .environment(store)
            .environment(library)
            .environment(dinner)
            .task { await store.load() }
    }
}

#Preview("Nora, a kid with an allergy") {
    MemberDetailPreview(member: Member.sampleFamily[4])
}

#Preview("Owen, away at camp") {
    MemberDetailPreview(member: Member.sampleFamily[3])
}

#Preview("Ann, the owner") {
    MemberDetailPreview(member: Member.sampleFamily[0])
}
