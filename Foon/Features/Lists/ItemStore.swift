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
    /// Only means anything while `keepOnHand` is on.
    var stockState: StockState = .in
    private var savedStock: StockState?
    private(set) var errorMessage: String?
    private(set) var isSaving = false

    private let client: ItemClient
    /// Queues a keep-on-hand change through the offline sync. Nil where there's no sync (previews).
    private let queueStock: ((StockState?) async -> Void)?

    init(item: ItemDetails, canRecategorize: Bool, client: ItemClient, queueStock: ((StockState?) async -> Void)? = nil) {
        self.item = item
        self.canRecategorize = canRecategorize
        self.client = client
        self.queueStock = queueStock
        note = item.note ?? ""
        category = item.category
        keepOnHand = item.keepOnHand
        savedStock = item.keepOnHand ? .in : nil
    }

    var canKeepOnHand: Bool { queueStock != nil }

    /// The offline cache knows stock better than the last server fetch: a toggle may still be queued.
    func startFromCache(keepOnHand cached: Bool, stock: StockState?) {
        item.keepOnHand = cached
        keepOnHand = cached
        stockState = stock ?? .in
        savedStock = cached ? stockState : nil
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
        let stock = keepOnHand ? stockState : nil
        if let queueStock, stock != savedStock {
            await queueStock(stock)
            savedStock = stock
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
