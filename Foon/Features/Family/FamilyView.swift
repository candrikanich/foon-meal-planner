import SwiftUI

struct FamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(DinnerStore.self) private var dinner
    @State private var addingMember = false
    @State private var editingRhythm = false
    @State private var confirmingSignOutEverywhere = false
    @State private var deletingAccount = false
    @State private var deletingHousehold = false
    @State private var exportURL: URL?

    private var isOwner: Bool { store.household?.owner == store.userID }

    private var canPlan: Bool { LibraryStore.canEdit(me: store.me, isOwner: isOwner) }

    private var accountDeletion: AccountDeletion {
        .outcome(household: store.household, me: store.me, userID: store.userID)
    }

    var body: some View {
        NavigationStack {
            List {
                if let household = store.household {
                    Section {
                        HStack(spacing: 12) {
                            Text(household.emoji ?? "🏡").font(.largeTitle).accessibilityHidden(true)
                            Text(household.name).font(.title2.bold())
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if isOwner, store.isUnsharedSample {
                        Section {
                            Button("Start your real family", systemImage: "house") { deletingHousehold = true }
                        } footer: {
                            Text("This is the sample family. Delete it and set up your own; you keep your account.")
                        }
                    }
                }

                Section("Family") {
                    ForEach(store.visibleMembers) { member in
                        NavigationLink {
                            MemberDetailView(memberID: member.id)
                        } label: {
                            MemberRow(member: member, isYou: member.userID == store.userID,
                                      invited: store.invitedMemberIDs.contains(member.id))
                        }
                    }
                }

                if canPlan {
                    Section {
                        Button("Rhythm and planning mix") { editingRhythm = true }
                    } footer: {
                        Text("When you plan, when the week starts, dinner time, and what goes in a week.")
                    }
                }

                if canPlan || store.canManagePeople {
                    Section {
                        if canPlan {
                            NavigationLink {
                                AwayDatesView()
                            } label: {
                                LabeledContent("Away dates", value: awaySummary)
                            }
                        }
                        // A person's usual schedule is theirs or a parent's to change.
                        if store.canManagePeople {
                            NavigationLink("Saved schedules") { AttendanceTemplatesView() }
                        }
                    } header: {
                        Text("Trips and seasons")
                    } footer: {
                        Text("Pause planning while you're all away, and switch everyone's usual nights home when the season changes.")
                    }
                }

                if canPlan {
                    Section {
                        NavigationLink {
                            KitchenView()
                        } label: {
                            LabeledContent("Kitchen", value: kitchenSummary)
                        }
                    } footer: {
                        Text("What you have to cook with, and when to start.")
                    }

                    Section {
                        NavigationLink {
                            FoodRulesView()
                        } label: {
                            LabeledContent("Food rules", value: foodRulesSummary)
                        }
                    } footer: {
                        Text("What your household skips, and when.")
                    }

                    Section {
                        NavigationLink {
                            DinnerJobsView()
                        } label: {
                            LabeledContent("Dinner jobs", value: dinnerJobsSummary)
                        }
                    } footer: {
                        Text("Optional helper jobs that rotate among whoever's home.")
                    }
                }

                ReminderSettingsSection()

                Section {
                    NavigationLink("Plan activity") { PlanActivityView() }
                } footer: {
                    Text("Who changed what on the plan, so two planners don't confuse each other.")
                }

                // Family order, not a ranking: credit, not a leaderboard.
                let cooks = Dictionary(dinner.cookTally.map { ($0.memberID, $0) }, uniquingKeysWith: { first, _ in first })
                let cooking = store.visibleMembers.filter { cooks[$0.id] != nil }
                if !cooking.isEmpty {
                    Section {
                        ForEach(cooking) { member in
                            if let tally = cooks[member.id] {
                                HStack(spacing: 12) {
                                    MemberAvatar(member: member)
                                    Text(member.firstName).font(.body.weight(.medium))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(tally.dinnersTitle)
                                        if tally.thanks > 0 {
                                            Text(tally.thanksTitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    } header: {
                        Text("Cooked this month")
                    } footer: {
                        Text("From the dinners logged after each meal. Tap Thanks, chef on This Week to say so.")
                    }
                }
                Section {
                    NavigationLink("What Foon keeps") { PrivacySummaryView() }
                    if store.canExport {
                        ExportButton(exportURL: $exportURL)
                    }
                    if isOwner {
                        Button("Delete household", role: .destructive) { deletingHousehold = true }
                    }
                    Button(accountDeletion.buttonTitle, role: .destructive) { deletingAccount = true }
                } header: {
                    Text("Your data")
                } footer: {
                    if let message = store.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else if isOwner {
                        Text("Delete household erases it for everyone and keeps your account. Deleting your account also deletes the household. Neither can be undone.")
                    } else if store.canExport {
                        Text("Export saves the household's meals, plans, lists, and family as a file. Deleting your account can't be undone.")
                    } else {
                        Text("Deleting your account can't be undone.")
                    }
                }

                Section {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                    Button("Sign out of all devices", role: .destructive) {
                        confirmingSignOutEverywhere = true
                    }
                } footer: {
                    if let message = session.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Use this if a phone is lost or shared. Every device, this one included, signs out right away.")
                    }
                }
            }
            .refreshable {
                await store.load()
                await loadDinners()
            }
            // Waits for the household, so the tally uses its time zone (the store's calendar is shared with This Week).
            .task(id: store.household?.id) { await loadDinners() }
            .navigationTitle("Family")
            .toolbar {
                if store.canManagePeople {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add member", systemImage: "person.badge.plus") {
                            addingMember = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Sign out of all devices?", isPresented: $confirmingSignOutEverywhere, titleVisibility: .visible
            ) {
                Button("Sign out everywhere", role: .destructive) {
                    Task { _ = await session.signOutEverywhere() }
                }
            } message: {
                Text("Foon signs out on every phone, tablet, and Mac using your account, including this one.")
            }
            .sheet(isPresented: $deletingAccount) { DeleteAccountView() }
            .sheet(isPresented: $deletingHousehold) { DeleteHouseholdView() }
            .sheet(isPresented: $addingMember) { MemberEditorView(member: nil) }
            .sheet(isPresented: $editingRhythm) { HouseholdRhythmView(store: store) }
        }
    }

    private var awaySummary: String {
        guard let settings = store.household?.planningSettings else { return String(localized: "None") }
        let today = settings.today()
        return settings.awayDates(endingOnOrAfter: today).first?.summary(today: today) ?? String(localized: "None")
    }

    private var dinnerJobsSummary: String {
        let count = store.household?.planningSettings.dinnerJobs.jobs.count ?? 0
        switch count {
        case 0: return String(localized: "Off", comment: "Family: the household doesn't use dinner jobs")
        case 1: return String(localized: "1 job", comment: "Family: how many dinner jobs the household uses")
        default: return String(localized: "\(count) jobs", comment: "Family: how many dinner jobs the household uses")
        }
    }

    private var foodRulesSummary: String {
        let count = store.household?.planningSettings.foodRules.count ?? 0
        switch count {
        case 0: return String(localized: "None", comment: "Family: the household has no food rules")
        case 1: return String(localized: "1 rule", comment: "Family: how many food rules the household has")
        default: return String(localized: "\(count) rules", comment: "Family: how many food rules the household has")
        }
    }

    private var kitchenSummary: String {
        let missing = store.household?.planningSettings.missingEquipment.count ?? 0
        switch missing {
        case 0: return String(localized: "Everything", comment: "Family: the household has all the kitchen equipment")
        case 1: return String(localized: "1 thing missing", comment: "Family: kitchen equipment the household lacks")
        default: return String(localized: "\(missing) things missing", comment: "Family: kitchen equipment the household lacks")
        }
    }

    private func loadDinners() async {
        guard let household = store.household else { return }
        await dinner.load(settings: household.planningSettings)
    }
}

struct MemberRow: View {
    @Environment(HouseholdStore.self) private var store
    let member: Member
    let isYou: Bool
    var invited = false

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatar(member: member)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.firstName).font(.body.weight(.medium))
                    if isYou {
                        Text("You").font(.caption).foregroundStyle(.secondary)
                    }
                    if member.guardian {
                        Text("Parent")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.15)))
                    }
                }
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let today = (store.household?.planningSettings ?? HouseholdSettings()).today()
        return ([member.ageTitle, member.roleTitle, member.statusTitle(today: today)]
                + (invited ? [String(localized: "Invite sent")] : [])).joined(separator: " · ")
    }
}

#Preview("Parent") {
    let store = HouseholdStore.preview()
    FamilyView()
        .environment(store)
        .environment(SessionStore(auth: .preview()))
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(PlanActivityStore(householdID: Household.sample.id, client: .preview(started: true)))
        .task { await store.load() }
}
