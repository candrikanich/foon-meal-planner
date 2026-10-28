import SwiftUI

/// From a link (docs/spec.md → Adding a meal): paste a recipe page, see what Foon read, scaled to the household, then
/// add it. A page with no recipe data keeps its title and link, to fill in later.
struct LinkImportView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    let onAdded: (UUID) -> Void

    @State private var link = ""
    @State private var imported: RecipeImport?
    @State private var draft: MealDraft?
    @State private var isWorking = false
    /// The page couldn't be read (down, or the site turns Foon away): the link can still be saved.
    @State private var unreadable: URL?

    private var householdSize: Int { max(household.visibleMembers.count, 1) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recipe link", text: $link, prompt: Text(verbatim: "https://"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(read)
                    Button(isWorking && draft == nil ? "Reading…" : "Read recipe", action: read)
                        .disabled(isWorking || link.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Most recipe sites work. Foon reads the recipe card, not the whole page.")
                }

                if let imported, let draft = Binding($draft) {
                    preview(imported, draft: draft)
                }

                if let message = library.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                        if let unreadable {
                            Button("Save just the link") { useLinkOnly(unreadable) }
                        }
                    } footer: {
                        if unreadable != nil {
                            Text("Some sites don't let apps read their recipes. You can add the ingredients yourself.")
                        }
                    }
                }
            }
            .navigationTitle("From a link")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(draft == nil || isWorking)
                }
            }
            .onAppear { library.clearError() }
            // A failed read shouldn't leave its message on the library behind this sheet.
            .onDisappear { library.clearError() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private func preview(_ imported: RecipeImport, draft: Binding<MealDraft>) -> some View {
        Section {
            TextField("Meal name", text: draft.name)
        } footer: {
            if imported.hasRecipe {
                if let servings = imported.recipe?.servings, servings != householdSize {
                    Text("Scaled from \(servings) servings to \(householdSize) for your family.")
                }
            } else {
                Text("No recipe card on that page, so Foon kept the title and link. Add ingredients when you can.")
            }
        }
        if !draft.wrappedValue.lines.isEmpty {
            Section("Ingredients") {
                ForEach(draft.wrappedValue.lines) { line in
                    LabeledContent(line.name, value: line.quantity)
                }
            }
        }
        let steps = draft.wrappedValue.stepsText.split(whereSeparator: \.isNewline).count
        if steps > 0 {
            Section {
                Text(steps == 1 ? String(localized: "1 step") : String(localized: "\(steps) steps"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func read() {
        guard !isWorking else { return }
        // Set before the task starts, so a quick second Return can't start another read; and the link as it was
        // when read, so editing it meanwhile can't change what "Save just the link" saves.
        isWorking = true
        let link = link
        Task {
            defer { isWorking = false }
            imported = nil
            draft = nil
            unreadable = nil
            if let result = await library.importRecipe(link) {
                imported = result
                draft = result.draft(householdSize: householdSize)
            } else {
                unreadable = LibraryStore.webLink(link)
            }
        }
    }

    private func useLinkOnly(_ url: URL) {
        library.clearError()
        let linkOnly = RecipeImport(recipe: nil, title: nil, url: url)
        imported = linkOnly
        draft = linkOnly.draft(householdSize: householdSize)
        unreadable = nil
    }

    private func add() {
        guard let draft else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            if let id = await library.create(draft) {
                dismiss()
                onAdded(id)
            }
        }
    }
}

#Preview {
    let household = HouseholdStore.preview()
    LinkImportView { _ in }
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(household)
        .task { await household.load() }
}
