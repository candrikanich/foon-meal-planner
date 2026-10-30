import SwiftData
import SwiftUI

/// What the share sheet sent, and what to do with it (docs/spec.md → Share Sheet extension): a recipe link goes to the
/// library or becomes an idea, a social post becomes an idea with its title and link, and text goes on the quick list.
struct SharedItemSheet: View {
    enum Outcome {
        /// Handled or discarded; the tab to show what happened, if any.
        case done(AppTab?)
        /// Not now: it comes back the next time Foon launches.
        case postponed
    }

    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(IdeasStore.self) private var ideas
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(\.itemClient) private var itemClient
    @Query private var items: [CachedItem]

    let item: SharedItem
    let finish: (Outcome) -> Void

    @State private var title = ""
    @State private var names: [String] = []
    @State private var importing = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// A photo or PDF as read, to check and correct: nil until it's been read.
    @State private var readDraft: MealDraft?
    @State private var readTruncated = false
    @State private var isReadingCaption = false

    private var route: ShareRouter.Route { ShareRouter.route(item.kind) }

    private var canAddToLibrary: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch route {
                case .recipeLink(let url, _): link(url, canImport: canAddToLibrary)
                case .socialLink(let url, _):
                    link(url, canImport: false)
                    if isReadingCaption {
                        Section { ProgressView("Looking for a recipe…") }
                    } else if readDraft != nil {
                        readSection
                    }
                case .shoppingList: shoppingList
                case .capture: readSection
                }
                Section {
                    Button("Discard", role: .destructive) { finish(.done(nil)) }.disabled(isWorking)
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Shared with Foon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { finish(.postponed) }.disabled(isWorking)
                }
            }
            .interactiveDismissDisabled()
            .onAppear(perform: start)
            .task {
                switch route {
                case .capture(let type): await read(type)
                case .socialLink(let url, _): await readCaption(url)
                default: break
                }
            }
            .sheet(isPresented: $importing) {
                if case .recipeLink(let url, _) = route {
                    LinkImportView(sharedLink: url) { _ in finish(.done(.library)) }
                }
            }
        }
    }

    private func start() {
        switch route {
        case .recipeLink(_, let shared), .socialLink(_, let shared): title = shared ?? ""
        case .shoppingList(let parsed): names = parsed
        case .capture: break
        }
    }

    /// Runs on this device; the file is deleted with the item once it's handled (docs/spec.md → Share Sheet extension).
    private func read(_ type: SharedItem.FileType) async {
        guard let url = SharedInbox.shared?.fileURL(for: item) else {
            readDraft = MealDraft(newNamed: "")
            return
        }
        let size = max(household.visibleMembers.count, 1)
        // Off the main actor, so a long file can't freeze Discard and Not now.
        let reading = Task.detached {
            let lines = await TextRecognizer.lines(in: url, type: type)
            try Task.checkCancellation()
            let capture = RecipeTextParser.parse(lines)
            return (capture.draft(householdSize: size), capture.isTruncated)
        }
        // Discard or Not now ends this view's task: the reading stops with it.
        guard let (draft, truncated) = await withTaskCancellationHandler(
            operation: { try? await reading.value }, onCancel: { reading.cancel() }
        ) else { return }
        readTruncated = truncated
        readDraft = draft
    }

    /// Planners only, since it's the same read as adding a link. Sites often turn apps away, and then this was just an
    /// idea all along, so a failure says nothing.
    private func readCaption(_ url: URL) async {
        guard canAddToLibrary else { return }
        isReadingCaption = true
        defer { isReadingCaption = false }
        let imported = await library.importRecipe(url.absoluteString)
        library.clearError()
        guard let imported else { return }
        let size = max(household.visibleMembers.count, 1)
        var draft: MealDraft?
        if imported.hasRecipe {
            draft = imported.draft(householdSize: size)
        } else if let capture = imported.caption.flatMap(RecipeTextParser.parseCaption) {
            readTruncated = capture.isTruncated
            draft = capture.draft(householdSize: size)
            if capture.name == nil { draft?.name = RecipeImport.clamped(title.isEmpty ? imported.title ?? "" : title, to: 80) }
            draft?.link = url.absoluteString
        }
        if let draft { readDraft = draft }
    }

    /// Photos read imperfectly, and allergy flags read these ingredients: everything's here to fix before it's saved.
    @ViewBuilder
    private var readSection: some View {
        if let draft = Binding($readDraft) {
            if draft.wrappedValue.name.isEmpty, draft.wrappedValue.lines.isEmpty, draft.wrappedValue.stepsText.isEmpty {
                Section {
                    Text("Foon couldn't find any text in that. If it's a locked PDF, remove the password and share it again.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Meal name", text: draft.name)
                } footer: {
                    Text("Read on this device, so check it over. Foon deletes the file when you're done here.")
                }
                Section {
                    ForEach(draft.lines) { $line in
                        HStack {
                            TextField("Amount", text: $line.quantity).frame(maxWidth: 90)
                            TextField("Ingredient", text: $line.name)
                        }
                    }
                    .onDelete { draft.wrappedValue.lines.remove(atOffsets: $0) }
                    Button("Add an ingredient", systemImage: "plus") {
                        draft.wrappedValue.lines.append(MealDraft.Line(quantity: "", name: ""))
                    }
                } header: {
                    Text("Ingredients")
                } footer: {
                    if readTruncated {
                        Text("That was more than a meal can hold, so some were left out. Allergy flags only see what's here.")
                    }
                }
                Section("Steps") {
                    TextField("One step per line", text: draft.stepsText, axis: .vertical).lineLimit(3...12)
                }
                readActions(draft.wrappedValue)
            }
        } else {
            Section { ProgressView("Reading…") }
        }
    }

    @ViewBuilder
    private func readActions(_ draft: MealDraft) -> some View {
        let hasName = !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        let items = ShareRouter.unique(draft.lines.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        Section {
            if canAddToLibrary {
                Button("Add to our meals", systemImage: "book") { Task { await addMeal(draft) } }
                    .disabled(isWorking || !hasName)
            }
            if !items.isEmpty {
                Button("Add to the quick list", systemImage: "cart.badge.plus") {
                    names = items
                    Task { await addToList() }
                }
                .disabled(isWorking || sync == nil)
            }
            // A social post already offers this above, with its link.
            if case .capture = route {
                Button("Save as an idea", systemImage: "lightbulb") { Task { await saveNamedIdea(draft.name) } }
                    .disabled(isWorking || household.me == nil || !hasName)
            }
        }
    }

    private func addMeal(_ draft: MealDraft) async {
        isWorking = true
        defer { isWorking = false }
        library.clearError()
        if await library.create(draft) != nil {
            finish(.done(.library))
        } else {
            errorMessage = library.errorMessage
            library.clearError()
        }
    }

    private func saveNamedIdea(_ name: String) async {
        guard let me = household.me,
              let request = NewRequest.build(kind: .name, from: me.id, mealID: nil, title: name, link: "", note: "",
                                             date: nil) else {
            errorMessage = String(localized: "Names can be up to \(NewRequest.titleLimit) characters.")
            return
        }
        await send(request)
    }

    @ViewBuilder
    private func link(_ url: URL, canImport: Bool) -> some View {
        Section {
            Link(destination: url) { Label(url.host() ?? url.absoluteString, systemImage: "safari") }
            TextField("What is it? (optional)", text: $title)
        }
        Section {
            if canImport {
                Button("Add to our meals", systemImage: "book") { importing = true }.disabled(isWorking)
            }
            Button("Save as an idea", systemImage: "lightbulb") { Task { await saveIdea(url) } }
                .disabled(isWorking || household.me == nil)
        } footer: {
            Text("Ideas wait in the Ideas tab for a planner to plan.")
        }
    }

    @ViewBuilder
    private var shoppingList: some View {
        Section {
            if names.isEmpty { Text("Nothing to add from that text.").foregroundStyle(.secondary) }
            ForEach(names, id: \.self) { Text($0) }
                .onDelete { names.remove(atOffsets: $0) }
        } header: {
            Text("For the quick list")
        }
        Section {
            Button("Add to the quick list", systemImage: "cart.badge.plus") { Task { await addToList() } }
                .disabled(isWorking || names.isEmpty || sync == nil)
        }
    }

    private func saveIdea(_ url: URL) async {
        guard let me = household.me,
              let request = NewRequest.build(kind: .link, from: me.id, mealID: nil, title: title,
                                             link: url.absoluteString, note: "", date: nil) else {
            errorMessage = String(localized: "Names can be up to \(NewRequest.titleLimit) characters.")
            return
        }
        await send(request)
    }

    private func send(_ request: NewRequest) async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        if await ideas.make(request) {
            finish(.done(.ideas))
        } else {
            // Shown here, not left behind on the Ideas tab.
            errorMessage = ideas.errorMessage
            ideas.clearError()
        }
    }

    private func addToList() async {
        guard let sync, let householdID = household.household?.id else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        let result = await QuickListAdder.add(names, items: items, householdID: householdID, itemClient: itemClient,
                                              sync: sync)
        if let message = result.message {
            names = result.failed
            errorMessage = message
        } else {
            finish(.done(.lists))
        }
    }
}

#Preview("A link") {
    let household = HouseholdStore.preview()
    SharedItemSheet(item: SharedItem(kind: .link(URL(string: "https://recipes.example/chili")!, title: "Best chili"))) { _ in }
        .environment(household)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await household.load() }
}

#Preview("A photo that can't be read") {
    let household = HouseholdStore.preview()
    SharedItemSheet(item: SharedItem(kind: .file(.image))) { _ in }
        .environment(household)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await household.load() }
}

#Preview("Text") {
    let household = HouseholdStore.preview()
    SharedItemSheet(item: SharedItem(kind: .text("milk, eggs, bread"))) { _ in }
        .environment(household)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await household.load() }
}
