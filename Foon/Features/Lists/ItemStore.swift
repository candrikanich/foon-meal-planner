import Foundation
import Observation

/// The item sheet's state: the note anyone at home can set, keep on hand (anyone, works offline), and the
/// category planners can change.
@Observable @MainActor
final class ItemStore {
    private(set) var item: ItemDetails
    let canRecategorize: Bool
    var note: String
    var category: ItemCategory
    var keepOnHand: Bool
    private(set) var errorMessage: String?
    private(set) var isSaving = false

    private let client: ItemClient
    /// Queues a keep-on-hand change through the offline sync. Nil where there's no sync (previews).
    private let queueStock: ((Bool) async -> Void)?

    init(item: ItemDetails, canRecategorize: Bool, client: ItemClient, queueStock: ((Bool) async -> Void)? = nil) {
        self.item = item
        self.canRecategorize = canRecategorize
        self.client = client
        self.queueStock = queueStock
        note = item.note ?? ""
        category = item.category
        keepOnHand = item.keepOnHand
    }

    var canKeepOnHand: Bool { queueStock != nil }

    /// The offline cache knows stock better than the last server fetch: a toggle may still be queued.
    func startFromCache(keepOnHand cached: Bool) {
        item.keepOnHand = cached
        keepOnHand = cached
    }

    /// Queues keep on hand first (it works offline), then sends the note and category if they changed.
    /// Returns whether the sheet can close.
    func save() async -> Bool {
        let cleaned: String?
        do {
            cleaned = try ItemNote.cleaned(note)
        } catch {
            errorMessage = String(localized: "Notes need 80 characters or fewer.")
            return false
        }

        var stockQueued = false
        if let queueStock, keepOnHand != item.keepOnHand {
            await queueStock(keepOnHand)
            item.keepOnHand = keepOnHand
            stockQueued = true
        }

        var changes = ItemChanges()
        if cleaned != item.note { changes.note = .some(cleaned) }
        if canRecategorize, category != item.category { changes.category = category }
        guard !changes.isEmpty else { return true }

        isSaving = true
        defer { isSaving = false }
        do {
            try await client.update(item.id, changes)
            item.note = cleaned
            if changes.category != nil { item.category = category }
            errorMessage = nil
            return true
        } catch {
            errorMessage = stockQueued || keepOnHand != item.keepOnHand
                ? String(localized: "Keep on hand is saved. The note needs a connection; try again.")
                : String(localized: "Couldn't save \(item.name). Check your connection and try again.")
            return false
        }
    }
}
