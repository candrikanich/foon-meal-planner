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

    private var route: ShareRouter.Route { ShareRouter.route(item.kind) }

    private var canAddToLibrary: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch route {
                case .recipeLink(let url, _): link(url, canImport: canAddToLibrary)
                case .socialLink(let url, _): link(url, canImport: false)
                case .shoppingList: shoppingList
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
        }
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

#Preview("Text") {
    let household = HouseholdStore.preview()
    SharedItemSheet(item: SharedItem(kind: .text("milk, eggs, bread"))) { _ in }
        .environment(household)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await household.load() }
}
