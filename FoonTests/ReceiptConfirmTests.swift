import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

/// Confirm goes through the sync queue, so a receipt scanned with no signal still lands (#61).
@MainActor
struct ReceiptConfirmTests {
    private let household = UUID()
    private let milk = UUID()
    private let cereal = UUID()
    private let milkLine = UUID()

    private var snapshot: SyncSnapshot {
        SyncSnapshot(
            plan: nil, nights: [],
            listItems: [ListItemRow(id: milkLine, householdID: household, itemID: milk, list: .quick, urgency: .whenever,
                                    source: .manual, note: nil, checkedAt: nil)],
            items: [ItemRow(id: milk, householdID: household, canonicalName: "Milk", category: .dairyEggs,
                            keepOnHand: false, stockState: nil),
                    ItemRow(id: cereal, householdID: household, canonicalName: "Cereal", category: .other,
                            keepOnHand: true, stockState: .out)]
        )
    }

    @Test func confirmingOfflineMarksItBoughtOnThisPhoneAndQueuesTheRest() async throws {
        let container = try SyncService.inMemoryContainer()
        let snapshot = snapshot
        let offline = Mutex(false)
        let sync = SyncService(householdID: household, context: container.mainContext, client: .fake(
            snapshot: { snapshot },
            send: { _ in if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) } }
        ))
        await sync.pull()
        offline.withLock { $0 = true }
        let items = [ReceiptItem(id: milk, name: "Milk"), ReceiptItem(id: cereal, name: "Cereal")]
        var review = ReceiptReview(ReceiptMatcher.match(["GV WHL MILK 3.48", "BAGGED SALAD 2.99"], items: items,
                                                        aliases: []))
        let salad = try #require(review.unrecognized.first)
        review.assign(salad.id, to: cereal)
        let store = ReceiptScanStore(householdID: household, review: review)

        let lines = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        let cached = try container.mainContext.fetch(FetchDescriptor<CachedItem>())
        let stock = Dictionary(uniqueKeysWithValues: cached.map {
            ($0.id, ReceiptStock(keepOnHand: $0.keepOnHand, state: $0.stockState))
        })
        await store.confirm(sync: sync, entries: ListEntry.entries(lines: lines, items: cached), stock: stock)

        #expect(store.phase == .done)
        #expect(store.boughtCount == 2)
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).allSatisfy { $0.checkedAt != nil })
        #expect(sync.stockState(cereal) == .in, "the staple is back in on this phone at once")
        #expect(sync.pendingCount == 4, "the check-off, its restock, the cereal's restock, and the correction wait for signal")
        #expect(store.suggestions.isEmpty, "neither was bought on an earlier trip")
    }

    /// PostgREST finds the function by its argument names.
    @Test func teachingNamesEveryArgument() throws {
        let params = TeachReceiptAliasParams(targetHousehold: UUID(), aliasText: "gv whl milk", targetItem: UUID())
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["target_household", "alias_text", "target_item"])
    }
}
