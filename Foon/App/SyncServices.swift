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

    /// Signed out or switched household: it never writes again, and the next ask gets a fresh one.
    func stop(_ service: SyncService) {
        service.stop()
        if current === service { current = nil }
    }

    /// Before the cache is wiped: one Siri started, which no screen owns, stops too.
    func stopCurrent() {
        current?.stop()
        current = nil
    }
}
