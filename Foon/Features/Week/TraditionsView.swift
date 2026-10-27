import SwiftUI

/// Standing traditions (Taco Tuesday, Pizza Friday): one meal or quick pick per weekday that Build my week
/// fills in and locks each week. A swap changes just that week.
struct TraditionsView: View {
    @Environment(WeekStore.self) private var week
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WeekMath.Weekday?

    /// The week as the family lives it, from the shopping day.
    private var weekdays: [WeekMath.Weekday] {
        let start = household.household?.planningSettings.weekStart ?? 7
        return (0..<7).map { WeekMath.Weekday(iso: (start - 1 + $0) % 7 + 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = week.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Section {
                    ForEach(weekdays) { weekday in
                        Button { editing = weekday } label: {
                            LabeledContent(weekday.name()) {
                                Text(summary(week.tradition(on: weekday.iso)))
                                    .foregroundStyle(week.tradition(on: weekday.iso) == nil ? .tertiary : .secondary)
                            }
                        }
                        .tint(Palette.ink)
                    }
                } footer: {
                    Text("Build my week fills these in and locks them. Swapping one changes just that week.")
                }
            }
            .navigationTitle("Traditions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { weekday in
                TraditionEditor(weekday: weekday)
            }
            .task {
                week.clearError()
                if !library.hasLoaded { await library.load(members: household.members) }
                if !week.traditionsLoaded { await week.load(settings: household.household?.planningSettings ?? HouseholdSettings()) }
            }
        }
    }

    private func summary(_ tradition: Tradition?) -> String {
        guard let tradition else { return String(localized: "None") }
        let what = switch tradition.pick {
        case .meal(let id):
            if let meal = library.meal(id) {
                meal.status.isInRotation ? meal.name
                    : String(localized: "\(meal.name) (archived, skipped)", comment: "Tradition row: meal out of rotation")
            } else {
                String(localized: "A removed meal")
            }
        case .quickPick(let pick): DayCardText.quickPickLabel(pick)
        }
        guard let name = tradition.name else { return what }
        return String(localized: "\(name): \(what)", comment: "Tradition row: its name, then the meal")
    }
}

/// Picks a weekday's tradition: a library meal or a quick pick, with an optional name for the chip.
private struct TraditionEditor: View {
    @Environment(WeekStore.self) private var week
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let weekday: WeekMath.Weekday

    @State private var name = ""
    @State private var pick: NightPick?
    @State private var search = ""
    @State private var isSaving = false

    private var meals: [LibraryMeal] {
        LibraryQuery.apply(LibraryQuery.entries(meals: library.meals, history: [], allergies: [], favorites: []),
                           filter: nil, sort: .recentlyAdded, search: search).map(\.meal)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Name (optional)") {
                    TextField(String(localized: "Taco \(weekday.name())", comment: "Tradition name placeholder"),
                              text: $name)
                        .onChange(of: name) { _, typed in
                            if typed.unicodeScalars.count > 40 { name = Tradition.cleanedName(typed) ?? "" }
                        }
                }
                Section("Something else") {
                    ForEach(QuickPick.all, id: \.self) { quickPick in
                        row(DayCardText.quickPickLabel(quickPick), systemImage: quickPick.systemImage,
                            selected: pick == .quickPick(quickPick)) { pick = .quickPick(quickPick) }
                    }
                }
                Section("A meal") {
                    if meals.isEmpty {
                        Text("No meals match.").foregroundStyle(.secondary)
                    }
                    ForEach(meals) { meal in
                        row(meal.name, systemImage: "fork.knife", selected: pick == .meal(meal.id)) {
                            pick = .meal(meal.id)
                        }
                    }
                }
                if week.tradition(on: weekday.iso) != nil {
                    Section {
                        Button("Remove this tradition", role: .destructive) { Task { await save(nil) } }
                            .disabled(isSaving)
                    }
                }
                if let message = week.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .searchable(text: $search, prompt: Text("Search your meals"))
            .navigationTitle(weekday.name())
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let pick else { return }
                        Task { await save(Tradition(weekday: weekday.iso, pick: pick, name: Tradition.cleanedName(name))) }
                    }
                    .disabled(pick == nil || isSaving)
                }
            }
            .onAppear {
                let current = week.tradition(on: weekday.iso)
                pick = current?.pick
                name = current?.name ?? ""
            }
        }
    }

    private func row(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.paprika) }
            }
        }
        .tint(Palette.ink)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ tradition: Tradition?) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        if await week.setTradition(tradition, on: weekday.iso) { dismiss() }
    }
}

#Preview {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    TraditionsView()
        .environment(household)
        .environment(week)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
