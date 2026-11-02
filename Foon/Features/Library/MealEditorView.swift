import SwiftUI

/// Edits a meal: name, servings, tags, who makes it, ingredients (typed or pasted naturally,
/// with autocomplete from the library), prep ahead, recipe steps, and the source link.
struct MealEditorView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household: HouseholdStore?
    @Environment(ReminderStore.self) private var reminders: ReminderStore?
    @Environment(\.dismiss) private var dismiss
    let meal: LibraryMeal

    @State private var draft: MealDraft
    @State private var newIngredients = ""
    @State private var newSide = ""
    @State private var isSaving = false

    init(meal: LibraryMeal) {
        self.meal = meal
        _draft = State(initialValue: MealDraft(meal))
    }

    private var suggestions: [String] {
        IngredientAutocomplete.suggestions(whileTyping: newIngredients, from: library.ingredientNames)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Stepper("Serves \(draft.servings)", value: $draft.servings, in: 1...50)
                    Picker("Made by", selection: $draft.madeByMemberID) {
                        Text("No one in particular").tag(UUID?.none)
                        ForEach(library.activeMembers) { member in
                            Text(member.firstName).tag(UUID?.some(member.id))
                        }
                    }
                }

                Section {
                    Picker("Time to cook", selection: $draft.cookMinutes) {
                        Text("Not sure").tag(Int?.none)
                        ForEach(MealText.cookTimeChoices(including: meal.cookMinutes), id: \.self) { minutes in
                            Text(MealText.cookTime(minutes: minutes)).tag(Int?.some(minutes))
                        }
                    }
                } footer: {
                    Text("Sets when This Week says to start cooking. If you're not sure, only quick and slow cooker dishes get an estimate.")
                }

                Section("Tags") {
                    ForEach(MealTag.allCases, id: \.self) { tag in
                        Toggle(tag.title, isOn: Binding(
                            get: { draft.tags.contains(tag) },
                            set: { isOn in
                                if isOn { draft.tags.insert(tag) } else { draft.tags.remove(tag) }
                            }
                        ))
                    }
                }

                ingredientsSection

                sidesSection

                prepSection

                Section {
                    TextEditor(text: $draft.stepsText)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Recipe steps")
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Optional. One step per line.")
                }

                Section("Recipe link") {
                    TextField("https://", text: $draft.link)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                if let message = library.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(meal.name)
            .onAppear { library.clearError() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            commitNewIngredients()
                            commitNewSide()
                            if await library.save(draft, mealID: meal.id) {
                                replanReminders()
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    /// Reminders are planned from a dish's prep steps, and a saved dish changes nothing `ReminderRunner` watches.
    private func replanReminders() {
        guard let reminders, let context = household?.reminderContext else { return }
        Task { await reminders.replan(context) }
    }

    private var ingredientsSection: some View {
        Section {
            ForEach($draft.lines) { $line in
                HStack {
                    TextField("Amount", text: $line.quantity)
                        .frame(maxWidth: 90)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Amount of \(line.name)")
                    TextField("Ingredient", text: $line.name)
                }
            }
            .onDelete { draft.lines.remove(atOffsets: $0) }
            .onMove { draft.lines.move(fromOffsets: $0, toOffset: $1) }

            TextField("Add ingredients", text: $newIngredients, axis: .vertical)
                .onSubmit(commitNewIngredients)
                .accessibilityHint("Type or paste several, separated by commas or new lines")
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    newIngredients = IngredientAutocomplete.completing(newIngredients, with: suggestion)
                } label: {
                    Label(suggestion, systemImage: "text.badge.plus")
                }
            }
        } header: {
            Text("Ingredients")
        } footer: {
            Text("Type them naturally, like \"1 lb ground beef, taco shells, cheese\".")
        }
    }

    /// Library meals first (they bring their own ingredients), then household items.
    private var sideSuggestions: [String] {
        let mealNames = library.meals.filter { $0.id != meal.id && $0.status.isInRotation }.map(\.name)
        return IngredientAutocomplete.suggestions(for: newSide, from: mealNames + library.ingredientNames, limit: 4)
            .filter { $0.caseInsensitiveCompare(newSide.trimmingCharacters(in: .whitespaces)) != .orderedSame }
    }

    private var sidesSection: some View {
        Section {
            ForEach(draft.sides, id: \.self) { side in
                switch side {
                case .meal(let id):
                    Label(library.meal(id)?.name ?? String(localized: "A removed meal"), systemImage: "fork.knife")
                case .item(let name):
                    Label(name, systemImage: "basket")
                }
            }
            .onDelete { draft.sides.remove(atOffsets: $0) }
            .onMove { draft.sides.move(fromOffsets: $0, toOffset: $1) }

            TextField("Add a side", text: $newSide)
                .onSubmit(commitNewSide)
                .accessibilityHint("A meal from your library, or something simple like salad or garlic bread")
            ForEach(sideSuggestions, id: \.self) { suggestion in
                Button {
                    newSide = suggestion
                    commitNewSide()
                } label: {
                    Label(suggestion, systemImage: "text.badge.plus")
                }
            }
        } header: {
            Text("Sides")
        } footer: {
            Text("Optional. A side from your library brings its ingredients to the list.")
        }
    }

    private var prepSuggestions: [PrepStep] {
        PrepSuggestions.suggestions(
            name: draft.name, ingredients: draft.lines.map(\.name), steps: draft.stepsText, tags: draft.tags,
            existing: draft.prepLines.map(\.step),
            keepsMeatFrozen: household?.household?.planningSettings.keepsMeatFrozen ?? true)
    }

    private var prepSection: some View {
        Section {
            ForEach($draft.prepLines) { $line in
                VStack(alignment: .leading) {
                    TextField("What to do", text: $line.step)
                    Picker("When", selection: $line.leadHours) {
                        Text("No reminder").tag(Int?.none)
                        ForEach(MealText.leadTimeChoices(including: line.leadHours), id: \.self) { hours in
                            Text(MealText.leadTime(hours: hours) ?? "").tag(Int?.some(hours))
                        }
                    }
                }
            }
            .onDelete { draft.prepLines.remove(atOffsets: $0) }

            ForEach(prepSuggestions, id: \.step) { suggestion in
                Button {
                    draft.prepLines.append(MealDraft.PrepLine(step: suggestion.step, leadHours: suggestion.leadHours))
                } label: {
                    Label(suggestion.step, systemImage: "text.badge.plus")
                }
                .accessibilityHint("Adds this prep step")
            }
            Button("Add a prep step", systemImage: "plus") {
                draft.prepLines.append(MealDraft.PrepLine(step: "", leadHours: 24))
            }
        } header: {
            Text("Prep ahead")
        } footer: {
            Text("Thawing, marinating, starting the slow cooker. Planners get a reminder this long before dinner.")
        }
    }

    private func commitNewSide() {
        draft.addSide(newSide, library: library.meals)
        newSide = ""
    }

    private func commitNewIngredients() {
        guard !newIngredients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.addIngredients(newIngredients)
        newIngredients = ""
    }
}

#Preview {
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    MealEditorView(meal: LibraryMeal.sampleLibrary[0])
        .environment(library)
        .task { await library.load(members: Member.sampleFamily) }
}
