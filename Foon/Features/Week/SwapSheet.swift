import SwiftUI

/// What a Swap row says, kept out of the view so it's testable. The card's rule, for this night: not a library entry's flags,
/// which are for the whole family, home or not. With no night (it's gone from under the sheet), nobody knows who's home, so
/// everyone counts.
enum SwapRow {
    static func allergyCheck(_ meal: LibraryMeal, on night: WeekNight?, library: [LibraryMeal], allergies: [MemberAllergies],
                             lookup: LibraryLookup) -> AllergyCheck {
        NightBadges.allergyCheck(dish: meal, library: library, allergies: allergies, home: home(night, allergies), lookup: lookup)
    }

    static func allergyCheck(catalog dish: CatalogDish, on night: WeekNight?, allergies: [MemberAllergies]) -> AllergyCheck {
        NightBadges.allergyCheck(catalog: dish, allergies: allergies, home: home(night, allergies))
    }

    static func allergyCheck(offer: FreezerStash.Offer, lookup: LibraryLookup) -> AllergyCheck {
        let note = offer.uncheckedNote ?? (lookup.isOutOfDate ? AllergyMatcher.outOfDateNote : nil)
        return AllergyCheck(flags: offer.flags, note: note)
    }

    /// For VoiceOver: the dish, its allergies, then the rest.
    static func label(_ name: String, allergies: AllergyCheck, details: [String] = []) -> String {
        let parts: [String] = [name] + allergies.texts + details
        return parts.joined(separator: ", ")
    }

    private static func home(_ night: WeekNight?, _ allergies: [MemberAllergies]) -> Set<UUID> {
        night?.allergyHome(allergies) ?? Set(allergies.map(\.memberID))
    }
}

/// Swap a night (docs/spec.md → Swap sheet): three suggestions with reason chips, the quick picks, then a
/// search of the library with Foon's ideas below and an inline quick add. The planner's pick locks the night.
struct SwapSheet: View {
    @Environment(WeekStore.self) private var week
    @Environment(IdeasStore.self) private var ideas: IdeasStore?
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(FreezerStore.self) private var freezer: FreezerStore?
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID

    @State private var search = ""
    @State private var suggestions: [BuildMyWeek.Suggestion] = []
    @State private var isWorking = false

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    private var libraryMatches: [LibraryEntry] {
        Array(LibraryQuery.apply(LibraryQuery.entries(meals: library.meals, library: library.meals, history: library.history,
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
                if let unwinding {
                    Section { Text(unwinding).font(.foonCaption).foregroundStyle(.secondary) }
                }
                if search.isEmpty {
                    suggestionsSection
                    heldBackSection
                    freezerSection
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
            .scrollDismissesKeyboard(.immediately)
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
                await freezer?.load()
            }
            // From a reminder about next week, this opens before that week has loaded, so it waits for the night.
            .task(id: night?.id) {
                if night != nil { await suggest() }
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
                    suggestionRow(meal, reason: suggestion.reason.text)
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

    private func suggestionRow(_ meal: LibraryMeal, reason: String) -> some View {
        let allergies = allergyCheck(meal)
        let equipment = settings.missingEquipment(for: meal)
        let details: [String] = [reason] + equipment.map(\.usuallyUsesText)
        return Button { Task { await choose(.meal(id: meal.id, name: meal.name)) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meal.name).font(.foonHeadline).foregroundStyle(Palette.ink)
                    AllergyChips(check: allergies)
                    Chip(text: reason, systemImage: "sparkles")
                    ForEach(equipment, id: \.self) { equipment in
                        Chip(text: equipment.usuallyUsesText, systemImage: "frying.pan", tint: Palette.paprika)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(SwapRow.label(meal.name, allergies: allergies, details: details))
    }

    /// Dishes a food rule held back from the suggestions, and why: a guess from the name, so the planner can still pick one.
    private var heldBack: [(meal: LibraryMeal, rules: [FoodRule])] {
        guard let night, night.date >= week.todayDay else { return [] }
        return FoodRuleMatcher.heldBack(on: night, week: week.week?.nights ?? [], meals: library.meals,
                                        rules: settings.foodRules)
    }

    private static let heldBackShown = 12

    @ViewBuilder
    private var heldBackSection: some View {
        let heldBack = heldBack
        if !heldBack.isEmpty {
            Section {
                ForEach(heldBack.prefix(Self.heldBackShown), id: \.meal.id) { entry in
                    heldBackRow(entry.meal, rules: entry.rules)
                }
            } header: {
                Text("Held back by your food rules")
            } footer: {
                if heldBack.count > Self.heldBackShown {
                    Text("Foon goes by names and ingredients, so it can be wrong either way. Tap one to plan it anyway, or search your meals for the rest.")
                } else {
                    Text("Foon goes by names and ingredients, so it can be wrong either way. Tap one to plan it anyway.")
                }
            }
        }
    }

    private func heldBackRow(_ meal: LibraryMeal, rules: [FoodRule]) -> some View {
        let allergies = allergyCheck(meal)
        let details: [String] = rules.map(\.looksLikeText)
        return Button { Task { await choose(.meal(id: meal.id, name: meal.name)) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.name).font(.foonHeadline).foregroundStyle(Palette.ink)
                AllergyChips(check: allergies)
                ForEach(rules, id: \.self) { rule in
                    Chip(text: rule.looksLikeText, systemImage: "fork.knife", tint: Palette.paprika)
                }
            }
        }
        .accessibilityLabel(SwapRow.label(meal.name, allergies: allergies, details: details))
        .accessibilityHint("Plans it anyway")
    }

    private func allergyCheck(_ meal: LibraryMeal) -> AllergyCheck {
        SwapRow.allergyCheck(meal, on: night, library: library.meals, allergies: library.allergies, lookup: library.lookup)
    }

    private func rulesBroken(by meal: LibraryMeal) -> [FoodRule] {
        guard let night, night.date >= week.todayDay else { return [] }
        return FoodRuleMatcher.broken(by: meal, on: night.date, rules: settings.foodRules, library: library.meals)
    }

    /// What changing this night also changes, said before it happens.
    private var unwinding: String? {
        night.flatMap { DoubleIt.changeWarning(for: $0, in: week.week?.nights ?? []) }
    }

    /// Dinners already cooked, oldest first, with allergy flags for whoever's home that night. Empty, it isn't shown.
    @ViewBuilder
    private var freezerSection: some View {
        if let night, let freezer {
            let offers = FreezerStash.offers(freezer.items, on: night, week: week.week?.nights ?? [], library: library.meals,
                                             notForMe: library.reactions.notForMe,
                                             snoozed: library.reactions.snoozed(today: week.todayDay),
                                             allergies: library.allergies, today: week.todayDay,
                                             foodRules: settings.foodRules)
            if !offers.isEmpty {
                Section("From the freezer") {
                    ForEach(offers, id: \.item.id) { offer in
                        freezerRow(offer)
                    }
                }
            }
        }
    }

    private func freezerRow(_ offer: FreezerStash.Offer) -> some View {
        let made = FreezerStash.madeText(offer.item.madeOn, today: week.todayDay)
        let allergies = SwapRow.allergyCheck(offer: offer, lookup: library.lookup)
        return Button {
            Task {
                await choose(.freezer(offer.item, reason: FreezerStash.reason(madeOn: offer.item.madeOn, today: week.todayDay)))
                await freezer?.load()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(offer.meal.name).font(.foonHeadline).foregroundStyle(Palette.ink)
                    Chip(text: made, systemImage: "snowflake")
                    AllergyChips(check: allergies)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(SwapRow.label(offer.meal.name, allergies: allergies, details: [made]))
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
                    libraryRow(entry.meal)
                }
            }
        }
        if !catalogMatches.isEmpty {
            Section("From Foon's ideas") {
                ForEach(catalogMatches) { dish in
                    catalogRow(dish)
                }
            }
        }
        if let archived = archivedMatch {
            Section {
                restoreRow(archived)
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

    private func libraryRow(_ meal: LibraryMeal) -> some View {
        let rules = rulesBroken(by: meal)
        let allergies = allergyCheck(meal)
        let details: [String] = rules.map(\.looksLikeText)
        return Button { Task { await choose(.meal(id: meal.id, name: meal.name)) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.name)
                AllergyChips(check: allergies)
                ForEach(rules, id: \.self) { rule in
                    Chip(text: rule.looksLikeText, systemImage: "fork.knife", tint: Palette.paprika)
                }
            }
        }
        .tint(Palette.ink)
        .accessibilityLabel(SwapRow.label(meal.name, allergies: allergies, details: details))
    }

    private func catalogRow(_ dish: CatalogDish) -> some View {
        let allergies = SwapRow.allergyCheck(catalog: dish, on: night, allergies: library.allergies)
        return Button { Task { await chooseCatalog(dish) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(dish.name, systemImage: "plus.circle")
                AllergyChips(check: allergies)
            }
        }
        .tint(Palette.ink)
        .accessibilityLabel(SwapRow.label(dish.name, allergies: allergies))
        .accessibilityHint("Adds it to your library and plans it")
    }

    private func restoreRow(_ meal: LibraryMeal) -> some View {
        let allergies = allergyCheck(meal)
        let text = String(localized: "Restore \(meal.name) and plan it")
        return Button { Task { await restore(meal) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: "arrow.uturn.backward")
                AllergyChips(check: allergies)
            }
        }
        .accessibilityLabel(SwapRow.label(text, allergies: allergies))
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
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
