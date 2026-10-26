import SwiftData
import SwiftUI

/// Runs the household's sync service while its content is on screen, and hands the service to the
/// screens that read the cache (This Week and Lists, M1).
struct SyncGate<Content: View>: View {
    let householdID: UUID
    let client: SyncClient
    @ViewBuilder let content: () -> Content

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var service: SyncService?

    var body: some View {
        content()
            .environment(service)
            .task(id: householdID) {
                let service = SyncService(householdID: householdID, context: context, client: client)
                self.service = service
                await service.start()
            }
            .onChange(of: scenePhase) { _, phase in
                // Back in the foreground: send anything queued and refresh.
                if phase == .active, let service { Task { await service.sync() } }
            }
            .onDisappear {
                // Signed out (or switched household): nothing still in flight may write to the cache.
                service?.stop()
            }
    }
}
