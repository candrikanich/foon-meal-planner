import Foundation
import Observation

/// Forwarded receipt emails waiting in Lists for anyone in the family to review (#237). Loaded when Lists shows, on
/// pull to refresh, and when the app comes back; no Realtime, since a receipt is rarely urgent.
@Observable @MainActor
final class ForwardedReceiptsStore {
    private(set) var receipts: [ForwardedReceipt] = []

    let householdID: UUID
    private let client: ForwardedReceiptClient

    init(householdID: UUID, client: ForwardedReceiptClient) {
        self.householdID = householdID
        self.client = client
    }

    /// Offline, what was last loaded stays: the receipts are still waiting on the server.
    func load() async {
        guard let loaded = try? await client.waiting(householdID) else { return }
        receipts = loaded
    }
}
