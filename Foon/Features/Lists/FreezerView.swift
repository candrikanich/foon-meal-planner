import SwiftUI

/// Cooked-ahead dinners with their dates. Everyone in the family keeps it up; planners plan a night from it in Swap.
struct FreezerView: View {
    @Environment(FreezerStore.self) private var freezer
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @State private var adding = false

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }
    private var today: CalendarDay { CalendarDay(.now, calendar: settings.dayCalendar) }

    var body: some View {
        List {
            if let message = freezer.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            Section {
                if freezer.inTheFreezer.isEmpty {
                    Text(freezer.hasLoaded ? "Nothing in the freezer yet. Cooked extra? Add it so it gets eaten."
                                           : "Loading what's in the freezer…")
                        .foregroundStyle(.secondary)
                }
                ForEach(freezer.inTheFreezer) { item in
                    row(item)
                        .swipeActions(edge: .leading) {
                            Button("Used up", systemImage: "checkmark") { change(.used, item) }.tint(Palette.herb)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Toss", systemImage: "archivebox") { change(.archived, item) }.tint(Palette.caution)
                        }
                        .contextMenu {
                            Button("Used up", systemImage: "checkmark") { change(.used, item) }
                            Button("Toss", systemImage: "archivebox") { change(.archived, item) }
                        }
                        .accessibilityAction(named: Text("Used up")) { change(.used, item) }
                        .accessibilityAction(named: Text("Toss")) { change(.archived, item) }
                }
            } header: {
                Text("In the freezer")
            } footer: {
                Text("Oldest first. Planners see these in Swap, with allergy flags for whoever's home that night.")
            }
            if !freezer.planned.isEmpty {
                Section("Planned") {
                    ForEach(freezer.planned) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            row(item)
                            if let night = item.plannedOn {
                                Text("Planned for \(DayCardText.dateLabel(for: night))")
                                    .font(.foonCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !freezer.gone.isEmpty {
                Section("Used up or tossed") {
                    ForEach(freezer.gone) { item in
                        HStack {
                            row(item)
                            Spacer()
                            Button("Put back") { change(.in, item) }
                                .font(.foonCaption)
                                .buttonStyle(.borderless)
                                .tint(Palette.paprika)
                                .accessibilityLabel("Put \(item.mealName) back in the freezer")
                        }
                    }
                }
            }
        }
        .navigationTitle("Freezer stash")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .refreshable { await freezer.load() }
        .sheet(isPresented: $adding) { FreezerAddSheet() }
        .task {
            if !library.hasLoaded { await library.load(members: household.members) }
            await freezer.load()
        }
    }

    private func row(_ item: FreezerItem) -> some View {
        let meal = library.meal(item.mealID)
        let flags = meal.map { dish in
            AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: dish, library: library.meals).map(\.name),
                                 members: library.allergies)
        } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.mealName).font(.foonHeadline).foregroundStyle(Palette.ink)
            Text(FreezerStash.madeText(item.madeOn, today: today)).font(.foonCaption).foregroundStyle(.secondary)
            ForEach(flags, id: \.summary) { flag in
                Chip(text: flag.summary, systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
            }
            if item.state == .in, let note = FreezerStash.notOfferedNote(for: meal) {
                Text(note).font(.foonCaption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func change(_ state: FreezerItem.State, _ item: FreezerItem) {
        Task { await freezer.setState(state, item: item) }
    }
}

/// Which dish and when it was made. The date runs up to today on the household's calendar, as the server checks it.
struct FreezerAddSheet: View {
    @Environment(FreezerStore.self) private var freezer
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var madeOn = Date.now
    @State private var saving = false

    private var calendar: Calendar { (household.household?.planningSettings ?? HouseholdSettings()).dayCalendar }

    private var meals: [LibraryMeal] {
        let inRotation = library.meals.filter(\.status.isInRotation).sorted { $0.name < $1.name }
        return search.isEmpty ? inRotation : inRotation.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = freezer.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Section {
                    DatePicker("Made on", selection: $madeOn, in: ...Date.now, displayedComponents: .date)
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, calendar.timeZone)
                }
                Section("Which dish?") {
                    if meals.isEmpty { Text("No dishes match. Add it to your library first.").foregroundStyle(.secondary) }
                    ForEach(meals) { meal in
                        Button(meal.name) { Task { await add(meal) } }
                            .tint(Palette.ink)
                            .accessibilityHint("Adds it to the freezer")
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search your meals"))
            .disabled(saving)
            .navigationTitle("Add to the freezer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    private func add(_ meal: LibraryMeal) async {
        saving = true
        defer { saving = false }
        if await freezer.add(mealID: meal.id, madeOn: CalendarDay(madeOn, calendar: calendar)) { dismiss() }
    }
}

#Preview("Add") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    FreezerAddSheet()
        .environment(household)
        .environment(library)
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .task {
            await household.load()
            await library.load(members: Member.sampleFamily)
        }
}

#Preview {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    NavigationStack { FreezerView() }
        .environment(household)
        .environment(library)
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .task { await household.load() }
}
