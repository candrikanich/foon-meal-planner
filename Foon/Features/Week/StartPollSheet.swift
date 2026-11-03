import SwiftData
import SwiftUI

/// Start a vote for tonight: what's in the house, ideas, and the quick picks, ready to go with one tap (docs/spec.md → Tonight poll).
struct StartPollSheet: View {
    @Environment(PollStore.self) private var polls: PollStore?
    @Environment(WeekStore.self) private var week
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(FreezerStore.self) private var freezer: FreezerStore?
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [CachedItem]
    let nightID: UUID
    /// What to start with ticked instead of the usual: the rescue's ideas, when it asks the family.
    var preselected: [PollChoice]? = nil
    var started: () -> Void = {}

    @State private var chosen: Set<PollChoice> = []
    @State private var minutes = PollRules.defaultDuration
    @State private var suggestions: [BuildMyWeek.Suggestion] = []
    @State private var hasStartingChoices = false

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }
    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    private var freezerOffers: [FreezerStash.Offer] {
        guard let night, let freezer else { return [] }
        return PollRules.oneOfEachDish(
            FreezerStash.offers(freezer.items, on: night, week: week.week?.nights ?? [], library: library.meals,
                                notForMe: library.reactions.notForMe, snoozed: library.reactions.snoozed(today: week.todayDay),
                                allergies: library.allergies, today: week.todayDay, foodRules: settings.foodRules))
    }

    private var backups: [LibraryMeal] {
        guard let night else { return [] }
        let stock = Dictionary(items.compactMap { item in item.stockState.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let inFreezer = Set(freezerOffers.map(\.meal.id))
        return PollRules.backupDinners(library: library.meals, night: night, week: week.week?.nights ?? [], stock: stock,
                                       notForMe: library.reactions.notForMe, snoozed: library.reactions.snoozed(today: week.todayDay),
                                       foodRules: settings.foodRules)
            .filter { !inFreezer.contains($0.id) }
    }

    /// Ideas that aren't already offered above: the server takes a dish once. Dishes it was handed come first, so
    /// each ticked one has its row.
    private var ideas: [LibraryMeal] {
        let offered = Set(backups.map(\.id)).union(freezerOffers.map(\.meal.id))
        let handed = (preselected ?? []).compactMap { choice -> UUID? in
            if case .meal(let id) = choice { id } else { nil }
        }
        var seen = offered
        return (handed + suggestions.map(\.mealID))
            .filter { seen.insert($0).inserted }
            .compactMap { library.meal($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = polls?.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                if !freezerOffers.isEmpty {
                    Section("From the freezer") {
                        ForEach(freezerOffers, id: \.item.id) { offer in
                            row(.freezer(offer.item.id), title: offer.meal.name,
                                allergies: SwapRow.allergyCheck(offer: offer, lookup: library.lookup))
                        }
                    }
                }
                if !backups.isEmpty {
                    Section("Backup dinners") {
                        ForEach(backups) { meal in row(.meal(meal.id), title: meal.name, allergies: allergyCheck(meal)) }
                    }
                }
                if !ideas.isEmpty {
                    Section("Ideas") {
                        ForEach(ideas) { meal in row(.meal(meal.id), title: meal.name, allergies: allergyCheck(meal)) }
                    }
                }
                Section("Quick picks") {
                    ForEach(QuickPick.allCases, id: \.self) { pick in
                        row(.quickPick(pick), title: DayCardText.quickPickLabel(pick), allergies: AllergyCheck())
                    }
                }
                Section {
                    Picker("Voting closes in", selection: $minutes) {
                        ForEach(PollRules.durations, id: \.self) { minutes in
                            Text("\(minutes) minutes", comment: "How long a tonight poll runs").tag(minutes)
                        }
                    }
                } footer: {
                    Text("Whoever's home tonight can vote. No vote counts as abstaining. A planner makes the winner tonight's dinner.")
                }
            }
            .navigationTitle("Vote on dinner")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start() } }
                        .disabled(polls?.isWorking != false || !(2 ... PollRules.optionLimit).contains(chosen.count))
                }
            }
            .task {
                polls?.clearError()
                if !library.hasLoaded { await library.load(members: household.members) }
                await freezer?.load()
                suggest()
                if !hasStartingChoices {
                    chosen = preselected.map { Set($0.prefix(PollRules.optionLimit)) }
                        ?? PollRules.startingChoices(freezer: freezerOffers, backups: backups)
                    hasStartingChoices = true
                }
            }
        }
    }

    private func row(_ choice: PollChoice, title: String, allergies: AllergyCheck) -> some View {
        let isChosen = chosen.contains(choice)
        return Button {
            if isChosen { chosen.remove(choice) } else if chosen.count < PollRules.optionLimit { chosen.insert(choice) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(Palette.ink)
                    AllergyChips(check: allergies)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark").foregroundStyle(Palette.paprika).accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(SwapRow.label(title, allergies: allergies))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func allergyCheck(_ meal: LibraryMeal) -> AllergyCheck {
        SwapRow.allergyCheck(meal, on: night, library: library.meals, allergies: library.allergies, lookup: library.lookup)
    }

    private func suggest() {
        guard let loaded = week.week else { return }
        let context = PlanningContext(meals: library.meals, history: library.history, settings: settings,
                                      members: household.visibleMembers, traditions: week.traditions,
                                      reactions: library.reactions)
        suggestions = BuildMyWeek.suggestions(night: nightID, inputs: context.inputs(for: loaded, today: week.todayDay),
                                              seed: UInt64.random(in: .min ... .max))
    }

    private func start() async {
        guard let polls else { return }
        // Rows' order, so the poll reads as the sheet did.
        let ordered = freezerOffers.map { PollChoice.freezer($0.item.id) } + backups.map { PollChoice.meal($0.id) }
            + ideas.map { PollChoice.meal($0.id) } + QuickPick.allCases.map { PollChoice.quickPick($0) }
        if await polls.start(nightID: nightID, minutes: minutes, choices: ordered.filter(chosen.contains)) {
            started()
            dismiss()
        }
    }
}

#Preview {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    return StartPollSheet(nightID: UUID())
        .environment(PollStore(client: .preview))
        .environment(household)
        .environment(week)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
