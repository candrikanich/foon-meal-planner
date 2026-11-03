import Foundation
import SwiftData

/// The one sync service for the signed-in household, shared by the open app (SyncGate) and Siri. Each service numbers
/// and replays its own queue, so two on the same cache could send a change twice or out of order.
@MainActor
final class SyncServices {
    static let shared = SyncServices()

    private var current: SyncService?

    /// The running service for this household, or a new one. Asking for another household stops the old one.
    func service(for householdID: UUID, context: ModelContext, client: SyncClient) -> SyncService {
        if let current, current.householdID == householdID, !current.isStopped { return current }
        current?.stop()
        let service = SyncService(householdID: householdID, context: context, client: client)
        current = service
        return service
    }

    /// Before the cache is wiped (sign-out, or no household): it never writes again, and the next ask gets a fresh one.
    func stopCurrent() {
        current?.stop()
        current = nil
    }
}
