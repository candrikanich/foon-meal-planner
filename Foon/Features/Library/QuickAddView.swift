import SwiftUI

/// Quick add (docs/spec.md → Adding a meal): type a name and save. Ingredients are optional and typed
/// naturally ("1 lb ground beef, taco shells, cheese"), with autocomplete from the household's items.
struct QuickAddView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onAdded: (UUID) -> Void

    @State private var name = ""
    @State private var ingredients = ""
    @State private var isSaving = false
    @FocusState private var focus: Field?

    private enum Field { case name, ingredients }

    private var parsed: [ParsedIngredient] { IngredientParser.parse(ingredients) }

    private var suggestions: [String] {
        IngredientAutocomplete.suggestions(whileTyping: ingredients, from: library.ingredientNames)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Meal name", text: $name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .ingredients }
                }

                Section {
                    TextField("1 lb ground beef, taco shells, cheese", text: $ingredients, axis: .vertical)
                        .focused($focus, equals: .ingredients)
                        .lineLimit(2...6)
                        .accessibilityLabel("Ingredients")
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            ingredients = IngredientAutocomplete.completing(ingredients, with: suggestion)
                        } label: {
                            Label(suggestion, systemImage: "text.badge.plus")
                        }
                    }
                } header: {
                    Text("Ingredients (optional)")
                } footer: {
                    Text("Separate them with commas or new lines. You can add them later too.")
                }

                if !parsed.isEmpty {
                    Section("Will add") {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.name, value: line.quantity ?? "")
                        }
                    }
                }

                if let message = library.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Quick add")
            .defaultFocus($focus, .name)
            .onAppear { library.clearError() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            isSaving = true
                            if let id = await library.quickAdd(name: name, ingredients: ingredients) {
                                dismiss()
                                onAdded(id)
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    QuickAddView(onAdded: { _ in })
        .environment(library)
        .task { await library.load(members: Member.sampleFamily) }
}
