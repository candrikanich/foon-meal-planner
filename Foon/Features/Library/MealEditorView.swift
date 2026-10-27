import SwiftUI

/// Edits a meal: name, servings, tags, who makes it, ingredients (typed or pasted naturally,
/// with autocomplete from the library), recipe steps, and the source link.
struct MealEditorView: View {
    @Environment(LibraryStore.self) private var library
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
                            if await library.save(draft, mealID: meal.id) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
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
