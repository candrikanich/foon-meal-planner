import SwiftUI

/// From a link (docs/spec.md → Adding a meal): paste a recipe page, see what Foon read, scaled to the household, then
/// add it. A page with no recipe data keeps its title and link, to fill in later.
struct LinkImportView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    /// A link from the share sheet: read at once.
    var sharedLink: URL?
    /// An idea's own name: it goes on the dish, whatever the page calls it.
    var name: String?
    let onAdded: (UUID) -> Void

    @State private var link = ""
    @State private var imported: RecipeImport?
    @State private var draft: MealDraft?
    @State private var isWorking = false
    /// The page couldn't be read (down, or the site turns Foon away): the link can still be saved.
    @State private var unreadable: URL?
    /// Saving just the link, so the preview doesn't claim to have seen the page.
    @State private var couldntRead = false
    /// Set before the save starts and kept until the sheet is gone: a second tap can't make a second dish, and the sheet
    /// can't be closed out from under a dish still being made.
    @State private var isAdding = false
    /// A caption too long to keep whole: some ingredients may be missing.
    @State private var isTruncated = false
    /// Read from a social post's caption, which is a guess: it can be corrected or dropped here.
    @State private var isFromCaption = false

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
                        .disabled(isWorking || isAdding || link.trimmingCharacters(in: .whitespaces).isEmpty)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isAdding) }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView().accessibilityLabel("Adding the dish")
                    } else {
                        Button("Add", action: add).disabled(draft == nil || isWorking)
                    }
                }
            }
            .onAppear {
                library.clearError()
                if let sharedLink, link.isEmpty {
                    link = sharedLink.absoluteString
                    read()
                }
            }
            .interactiveDismissDisabled(isAdding)
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
            if let note = imported.noIngredientsNote(lineCount: draft.wrappedValue.lines.count, couldntRead: couldntRead) {
                Text(note)
            } else if let servings = imported.recipe?.servings, servings != householdSize {
                Text("Scaled from \(servings) servings to \(householdSize) for your family.")
            }
        }
        if !draft.wrappedValue.lines.isEmpty {
            Section {
                ForEach(draft.wrappedValue.lines) { line in
                    LabeledContent(line.name, value: line.quantity)
                }
                .onDelete { draft.wrappedValue.lines.remove(atOffsets: $0) }
            } header: {
                Text("Ingredients")
            } footer: {
                if isTruncated {
                    Text("That was too long to keep it all, so some may be missing. Allergy flags only see what's here.")
                } else if isFromCaption {
                    Text("Read from the post's caption, so check it over. Swipe to remove anything that isn't an ingredient.")
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
        if isFromCaption, steps > 0 || !draft.wrappedValue.lines.isEmpty {
            Section {
                Button("Keep just the name and link") {
                    draft.wrappedValue.lines = []
                    draft.wrappedValue.stepsText = ""
                }
            }
        }
    }

    private func read() {
        guard !isWorking, !isAdding else { return }
        // Set before the task starts, so a quick second Return can't start another read; and the link as it was
        // when read, so editing it meanwhile can't change what "Save just the link" saves.
        isWorking = true
        let link = link
        Task {
            defer { isWorking = false }
            imported = nil
            draft = nil
            unreadable = nil
            couldntRead = false
            isTruncated = false
            isFromCaption = false
            if let result = await library.importRecipe(link) {
                imported = result
                if let read = result.captionRecipe(householdSize: householdSize, named: name) {
                    draft = read.draft
                    isTruncated = read.isTruncated
                    isFromCaption = true
                } else {
                    draft = result.draft(householdSize: householdSize, named: name)
                }
            } else {
                unreadable = LibraryStore.webLink(link)
            }
        }
    }

    private func useLinkOnly(_ url: URL) {
        library.clearError()
        let linkOnly = RecipeImport(recipe: nil, title: nil, url: url)
        imported = linkOnly
        draft = linkOnly.draft(householdSize: householdSize, named: name)
        unreadable = nil
        couldntRead = true
    }

    private func add() {
        guard let draft, !isAdding else { return }
        isAdding = true
        Task {
            guard let id = await library.create(draft) else {
                isAdding = false
                return
            }
            onAdded(id)
            dismiss()
        }
    }
}

#Preview("From an idea") {
    let household = HouseholdStore.preview()
    LinkImportView(sharedLink: URL(string: "https://recipes.example/gnocchi"), name: "Sheet-pan gnocchi") { _ in }
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(household)
        .task { await household.load() }
}

#Preview {
    let household = HouseholdStore.preview()
    LinkImportView { _ in }
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(household)
        .task { await household.load() }
}
