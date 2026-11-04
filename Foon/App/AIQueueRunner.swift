import SwiftUI

extension EnvironmentValues {
    @Entry var aiJobClient = AIJobClient.preview
}

/// Runs the household's AI queue while the app's open: on launch and each time it comes back to the foreground. Hands the
/// store to the screens that tidy recipes or show that they're being tidied, and puts a result into the dish it was for.
struct AIQueueRunner: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HouseholdStore.self) private var household
    @State private var store: AIQueueStore
    private let library: LibraryStore

    init(householdID: UUID, client: AIJobClient, library: LibraryStore, ai: AIService = .live) {
        _store = State(initialValue: AIQueueStore(householdID: householdID, runner: AIJobRunner(client: client, ai: ai),
                                                  shelf: .live(householdID: householdID)))
        self.library = library
    }

    private var isPlanner: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    func body(content: Content) -> some View {
        content
            .environment(store)
            .onChange(of: isPlanner, initial: true) { _, planner in store.isPlanner = planner }
            .task {
                // Read fresh and saved only if unchanged, so an edit on another phone since the last load wins.
                let applier = RecipeApplier.live(library.client)
                store.applyRecipe = { [library] watch, recipe in
                    let outcome = await applier.apply(recipe, for: watch)
                    if outcome == .applied { await library.reload() }
                    return outcome
                }
                store.isPlanner = isPlanner
                await store.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh() } }
            }
    }
}
