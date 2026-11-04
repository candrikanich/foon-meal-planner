import SwiftUI

extension EnvironmentValues {
    @Entry var aiJobClient = AIJobClient.preview
}

/// Runs the household's AI queue while the app's open: on launch and each time it comes back to the foreground. Hands the
/// store to the screens that submit jobs or show their results.
struct AIQueueRunner: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AIQueueStore

    init(householdID: UUID, client: AIJobClient, ai: AIService = .live) {
        _store = State(initialValue: AIQueueStore(householdID: householdID, runner: AIJobRunner(client: client, ai: ai)))
    }

    func body(content: Content) -> some View {
        content
            .environment(store)
            .task { await store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh() } }
            }
    }
}
