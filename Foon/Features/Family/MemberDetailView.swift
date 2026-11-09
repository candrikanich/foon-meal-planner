import SwiftUI

/// Who someone is, at a glance (docs/spec.md → Family tab). Everyone in the household sees it; what they can change is in
/// the editor, and allergies are a parent's, or an adult's own (#285). Looks the member up each time, so an edit shows as
/// soon as it's saved.
struct MemberDetailView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(DinnerStore.self) private var dinner
    @Environment(\.dismiss) private var dismiss
    let memberID: UUID
    @State private var editing = false
    /// Whether a parent has agreed to keep allergies; nil until known. Read only on an adult's own profile when they
    /// aren't a parent, so one in a family that answered No never sees Add my allergies.
    @State private var householdAgreed: Bool?

    private var member: Member? {
        store.members.first { $0.id == memberID && $0.status != .removed }
    }

    /// Changes once the family loads, so the agreement is read then rather than missed.
    private var isOwnAdultProfile: Bool {
        member.map { store.allergyScope(for: $0) == .own } ?? false
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
        .task(id: store.household?.id) { await store.loadTriedThisMonth() }
        .task(id: isOwnAdultProfile) {
            guard isOwnAdultProfile, let household = store.household else { return }
            // Unknown counts as no: the sheet would refuse to add anyway.
            householdAgreed = (try? await store.client.allergyAlerts(household.id)) == .on
        }
        .onChange(of: member == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func content(_ member: Member) -> some View {
        List {
            MemberAboutSection(member: member, today: today,
                               invited: store.invitedMemberIDs.contains(member.id), isYou: member.userID == store.userID)
            MemberInviteSection(member: member)
            MemberScheduleSection(member: member, today: today, canEdit: store.editScope(for: member).schedule)
            MemberNotificationsSection(member: member)
            if library.hasLoaded {
                if library.lastLoadFailed { staleNotice }
                MemberAllergySection(member: member, allergies: library.allergies.first { $0.memberID == member.id },
                                     scope: store.allergyScope(for: member), householdAgreed: householdAgreed == true)
                MemberTasteSections(member: member, profile: TasteProfile(
                    memberID: member.id, verdicts: library.reactions.verdicts, notes: library.servingNotes, meals: library.meals
                ))
            } else if library.lastLoadFailed {
                Section {
                    Text("Couldn't load allergies and favorites. Check your connection and try again.")
                    Button("Try again") { Task { await library.load(members: store.members) } }
                }
            } else {
                Section { ProgressView() }
            }
            // Left out at zero too, and while loading or offline: it celebrates trying, it never reports a lack of it.
            if let tried = TriedNew.monthTitle(for: member.id, in: store.triedThisMonth ?? []) {
                Section("Trying new things") {
                    Label(tried, systemImage: "sparkles")
                }
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

    /// What's below is from the last time this phone could load it. Allergies may have changed since.
    private var staleNotice: some View {
        Section {
            Text("Couldn't check for changes, so allergies and favorites may be out of date.")
            Button("Try again") { Task { await library.load(members: store.members) } }
        }
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
    let scope: HouseholdStore.AllergyScope
    let householdAgreed: Bool
    @State private var editing = false
    @State private var confirmingRemoval = false
    @State private var removal: OwnAllergiesRemoval?

    /// Parents always; an adult on their own profile once there's something to change or a parent has agreed.
    private var canOpenEditor: Bool {
        switch scope {
        case .asParent: true
        case .own: allergies != nil || householdAgreed
        case .none: false
        }
    }

    var body: some View {
        // A family without allergies never sees this, except a parent, who gets the way to add one later.
        if allergies != nil || canOpenEditor {
            Section {
                if let allergies {
                    Text(allergies.displayNames.joined(separator: ", "))
                }
                if canOpenEditor {
                    Button(editLabel) { editing = true }
                        .sheet(isPresented: $editing) {
                            MemberAllergiesView(member: member, ownProfile: scope == .own, household: store.client,
                                                library: library.client)
                        }
                }
                if scope == .own, allergies != nil {
                    removeOwnButton
                }
            } header: {
                Text("Allergies")
            } footer: {
                Text(footer)
            }
        }
    }

    private var editLabel: LocalizedStringKey {
        switch (scope, allergies == nil) {
        case (.own, true): "Add my allergies"
        case (.own, false): "Change my allergies"
        case (_, true): "Add allergies"
        case (_, false): "Change allergies"
        }
    }

    private var footer: LocalizedStringKey {
        switch scope {
        case .asParent: "Everyone in the family sees these. Foon flags dishes, and you still check labels."
        case .own: "You can change yours anytime, and a parent can too. Foon flags dishes, and you still check labels."
        case .none: "A parent keeps these up to date. Foon flags dishes, and you still check labels."
        }
    }

    @ViewBuilder private var removeOwnButton: some View {
        Button("Remove my allergies", role: .destructive) { confirmingRemoval = true }
            .disabled(removal?.isRemoving == true)
            .accessibilityHint("Deletes all of your allergies at once")
            .confirmationDialog("Remove your allergies?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove my allergies", role: .destructive) { Task { await removeOwn() } }
            } message: {
                Text("Foon deletes them all and stops flagging dishes for you. You or a parent can add them back.")
            }
        if let message = removal?.errorMessage {
            Text(message).foregroundStyle(.red)
        }
    }

    private func removeOwn() async {
        let removal = removal ?? OwnAllergiesRemoval(memberID: member.id, household: store.client)
        self.removal = removal
        guard await removal.remove() else { return }
        await library.showAllergies(AllergyChoice(), for: member, members: store.members)
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

#Preview("Ben, tried one new dish this month") {
    MemberDetailPreview(member: Member.sampleFamily[1])
}

#Preview("Nora, a kid with an allergy, trying new dishes") {
    MemberDetailPreview(member: Member.sampleFamily[4])
}

#Preview("Owen, away at camp") {
    MemberDetailPreview(member: Member.sampleFamily[3])
}

#Preview("Ann, the owner") {
    MemberDetailPreview(member: Member.sampleFamily[0])
}

#Preview("Grace, not a parent, on her own profile with an allergy") {
    let graceUser = UUID()
    var family = Member.sampleFamily
    family[2].userID = graceUser
    let grace = family[2]
    var library = LibraryClient.preview()
    library.allergies = { _ in [AllergyRow(memberID: grace.id, allergen: .peanuts, customText: nil)] }
    return MemberDetailPreview(store: HouseholdStore(userID: graceUser, client: .preview(members: family)),
                               library: LibraryStore(householdID: Household.sample.id, client: library),
                               member: grace)
}
