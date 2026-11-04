import SwiftUI

extension EnvironmentValues {
    @Entry var aiJobClient = AIJobClient.preview
}

/// Runs the household's AI queue while the app's open: on launch and each time it comes back to the foreground. Hands the
/// store to the screens that submit jobs or show their results, and puts a recipe result into the meal it was for.
struct AIQueueRunner: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AIQueueStore
    private let library: LibraryStore

    init(householdID: UUID, client: AIJobClient, library: LibraryStore, ai: AIService = .live) {
        _store = State(initialValue: AIQueueStore(householdID: householdID, runner: AIJobRunner(client: client, ai: ai),
                                                  shelf: .live(householdID: householdID)))
        self.library = library
    }

    func body(content: Content) -> some View {
        content
            .environment(store)
            .task {
                store.applyRecipe = { [library] watch, recipe in await Self.apply(recipe, for: watch, to: library) }
                await store.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh() } }
            }
    }

    /// The meal as the library has it now, so an edit made anywhere since it was saved is kept (`RecipeMerge`).
    private static func apply(_ recipe: StructuredRecipe, for watch: RecipeWatch,
                              to library: LibraryStore) async -> AIQueueStore.ApplyOutcome {
        guard library.hasLoaded else { return .retry }
        // Deleted since, or nothing left to change: either way, nothing to do.
        guard let meal = library.meal(watch.mealID),
              let draft = RecipeMerge.merged(MealDraft(meal), baseline: watch.baseline, recipe: recipe),
              (try? draft.validated()) != nil else { return .finished }
        guard await library.save(draft, mealID: meal.id) else {
            // Offline, say: tried again on the next refresh, without an error on a screen nobody saved from.
            library.clearError()
            return .retry
        }
        return .finished
    }
}
