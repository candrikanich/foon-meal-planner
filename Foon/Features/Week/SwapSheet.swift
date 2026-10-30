import SwiftUI

/// Swap a night (docs/spec.md → Swap sheet): three suggestions with reason chips, the quick picks, then a
/// search of the library with Foon's ideas below and an inline quick add. The planner's pick locks the night.
struct SwapSheet: View {
    @Environment(WeekStore.self) private var week
    @Environment(IdeasStore.self) private var ideas: IdeasStore?
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID

    @State private var search = ""
    @State private var suggestions: [BuildMyWeek.Suggestion] = []
    @State private var isWorking = false

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    private var libraryMatches: [LibraryEntry] {
        Array(LibraryQuery.apply(LibraryQuery.entries(meals: library.meals, history: library.history,
                                                      allergies: library.allergies, favorites: []),
                                 filter: nil, sort: .notLately, search: search).prefix(12))
    }

    private var typedName: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An archived meal with exactly the typed name: offered back rather than added again.
    private var archivedMatch: LibraryMeal? {
        library.meals.first { $0.status == .archived && $0.name.caseInsensitiveCompare(typedName) == .orderedSame }
    }

    private var canQuickAdd: Bool {
        !typedName.isEmpty && !library.meals.contains { $0.name.caseInsensitiveCompare(typedName) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = week.errorMessage ?? library.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                if search.isEmpty {
                    suggestionsSection
                    quickPicksSection
                    if night?.isPlanned == true {
                        Section {
                            Button("Leave it empty", role: .destructive) { Task { await choose(.empty) } }
                        } footer: {
                            Text("Fill or Pick for me can plan it again.")
                        }
                    }
                } else {
                    searchResults
                }
            }
            .searchable(text: $search, prompt: Text("Search your meals or add one"))
            .disabled(isWorking)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                week.clearError()
                library.clearError()
                await suggest()
            }
        }
    }

    private var title: String {
        guard let night else { return String(localized: "Swap") }
        return String(localized: "Swap \(DayCardText.dayLabel(for: night.date, today: week.todayDay))",
                      comment: "Swap sheet title: the night, e.g. Tonight or Thursday")
    }

    // MARK: - Sections

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if suggestions.isEmpty {
                Text("No suggestions fit this night. Search your meals instead.").foregroundStyle(.secondary)
            }
            ForEach(suggestions, id: \.mealID) { suggestion in
                if let meal = library.meal(suggestion.mealID) {
                    Button { Task { await choose(.meal(id: meal.id, name: meal.name)) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meal.name).font(.foonHeadline).foregroundStyle(Palette.ink)
                                Chip(text: suggestion.reason.text, systemImage: "sparkles")
                                ForEach(settings.missingEquipment(for: meal), id: \.self) { equipment in
                                    Chip(text: equipment.usuallyUsesText, systemImage: "frying.pan", tint: Palette.paprika)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel(([meal.name, suggestion.reason.text]
                        + settings.missingEquipment(for: meal).map(\.usuallyUsesText)).joined(separator: ", "))
                }
            }
        } header: {
            HStack {
                Text("Suggestions")
                Spacer()
                Button("More ideas", systemImage: "arrow.clockwise") { Task { await suggest() } }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("More ideas")
            }
        } footer: {
            if settings.setsAsideDishes(in: library.meals), let night, night.date >= week.todayDay {
                Text("Foon holds back dishes that usually use kitchen equipment you don't have, unless few others fit. Search your meals to plan one anyway.")
            }
        }
    }

    private var quickPicksSection: some View {
        Section("Something else") {
            ForEach(QuickPick.all, id: \.self) { pick in
                Button { Task { await choose(.quickPick(pick)) } } label: {
                    Label(DayCardText.quickPickLabel(pick), systemImage: pick.systemImage)
                }
                .tint(Palette.ink)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let catalogMatches = LibraryQuery.catalogMatches(library.catalog, search: search, library: library.meals)
        if !libraryMatches.isEmpty {
            Section("Your meals") {
                ForEach(libraryMatches) { entry in
                    Button(entry.meal.name) { Task { await choose(.meal(id: entry.meal.id, name: entry.meal.name)) } }
                        .tint(Palette.ink)
                }
            }
        }
        if !catalogMatches.isEmpty {
            Section("From Foon's ideas") {
                ForEach(catalogMatches) { dish in
                    Button { Task { await chooseCatalog(dish) } } label: {
                        Label(dish.name, systemImage: "plus.circle")
                    }
                    .tint(Palette.ink)
                    .accessibilityHint("Adds it to your library and plans it")
                }
            }
        }
        if let archived = archivedMatch {
            Section {
                Button { Task { await restore(archived) } } label: {
                    Label(String(localized: "Restore \(archived.name) and plan it"), systemImage: "arrow.uturn.backward")
                }
            } footer: {
                Text("It's archived; this puts it back in rotation.")
            }
        }
        if canQuickAdd {
            Section {
                Button { Task { await quickAdd() } } label: {
                    Label(String(localized: "Add “\(typedName)” as a new dish"), systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Adds it to your library; you can add ingredients later.")
            }
        }
    }

    // MARK: - Actions

    private func suggest() async {
        if !library.hasLoaded { await library.load(members: household.members) }
        guard let week = week.week else { return }
        let context = PlanningContext(meals: library.meals, history: library.history, settings: settings,
                                      members: household.visibleMembers, traditions: self.week.traditions,
                                      reactions: library.reactions)
        suggestions = BuildMyWeek.suggestions(night: nightID, inputs: context.inputs(for: week, today: self.week.todayDay),
                                              seed: UInt64.random(in: .min ... .max))
    }

    private func choose(_ choice: WeekStore.SwapChoice) async {
        isWorking = true
        defer { isWorking = false }
        if await week.swap(nightID: nightID, to: choice) { await swapped() }
    }

    /// Adds a starter dish to the library, then plans it. If the swap fails, the dish is already in
    /// "Your meals", so trying again doesn't add it twice.
    private func chooseCatalog(_ dish: CatalogDish) async {
        isWorking = true
        defer { isWorking = false }
        guard let id = await library.add(dish) else { return }
        if await week.swap(nightID: nightID, to: .meal(id: id, name: library.meal(id)?.name ?? dish.name)) { await swapped() }
    }

    private func quickAdd() async {
        isWorking = true
        defer { isWorking = false }
        let name = typedName
        guard let id = await library.quickAdd(name: name, ingredients: "") else { return }
        if await week.swap(nightID: nightID, to: .meal(id: id, name: library.meal(id)?.name ?? name)) { await swapped() }
    }

    private func restore(_ meal: LibraryMeal) async {
        isWorking = true
        defer { isWorking = false }
        await library.setArchived(false, mealID: meal.id)
        guard library.meal(meal.id)?.status.isInRotation == true else { return }
        if await week.swap(nightID: nightID, to: .meal(id: meal.id, name: meal.name)) { dismiss() }
    }

    /// A swap can take a requested dish off its night (or put one on it): the ideas follow.
    private func swapped() async {
        await ideas?.sync(with: week.week, today: week.todayDay, requestNights: week.requestNights, away: week.awayDates)
        dismiss()
    }
}

#Preview {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    SwapSheet(nightID: UUID())
        .environment(household)
        .environment(week)
        .environment(library)
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
