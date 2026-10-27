import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

struct ItemCategoryTests {
    @Test func everyCategoryHasAName() {
        #expect(ItemCategory.personalCare.title == "Personal care")
        #expect(ItemCategory.meatSeafood.title == "Meat and seafood")
        #expect(Set(ItemCategory.allCases.map(\.title)).count == ItemCategory.allCases.count)
    }

    @Test func nonFoodCategoriesAreMarked() {
        #expect(!ItemCategory.household.isFood)
        #expect(!ItemCategory.personalCare.isFood)
        #expect(ItemCategory.produce.isFood)
        #expect(ItemCategory.other.isFood, "unknown items are treated as groceries")
    }

    /// Store mode walks the aisles in this order: fresh first, frozen near the end, non-food last.
    @Test func storeOrderPutsNonFoodLast() {
        let order = ItemCategory.storeOrder
        #expect(order.first == .produce)
        #expect(order.suffix(3) == [.household, .personalCare, .other])
        #expect(Set(order) == Set(ItemCategory.allCases))
    }

    @Test func anUnknownCategoryReadsAsOtherInsteadOfBreakingSync() throws {
        let data = Data(#"["produce", "garden_supplies", "personal_care"]"#.utf8)
        #expect(try JSONDecoder().decode([ItemCategory].self, from: data) == [.produce, .other, .personalCare])
    }

    @Test(arguments: [
        ("Paper towels", ItemCategory.household), ("dish soap", .household), ("Trash bags", .household),
        ("laundry detergent", .household), ("aluminum foil", .household), ("AA batteries", .household),
        ("Toothpaste", .personalCare), ("shampoo", .personalCare), ("Diapers", .personalCare),
        ("sunscreen", .personalCare), ("hand soap", .personalCare)
    ])
    func nonFoodNamesGuessTheirCategory(name: String, category: ItemCategory) {
        #expect(ItemCategory.guess(for: name) == category)
    }

    @Test(arguments: [
        ("disinfecting wipes", ItemCategory.household), ("Clorox wipes", .household), ("scouring pads", .household),
        ("baby wipes", .personalCare)
    ])
    func cleaningSuppliesAreHouseholdNotPersonalCare(name: String, category: ItemCategory) {
        #expect(ItemCategory.guess(for: name) == category)
    }

    @Test(arguments: ["ground beef", "foil-wrapped burritos", "Soap opera cake", "milk", "paper-thin ham",
                      "sponge cake", "sponge fingers", "candy floss", "cotton candy"])
    func foodIsNotGuessedAsNonFood(name: String) {
        #expect(ItemCategory.guess(for: name) == nil)
    }
}

struct ItemNoteTests {
    @Test func notesAreTrimmedAndBlankMeansNone() throws {
        #expect(try ItemNote.cleaned("  Vanilla, not plain ") == "Vanilla, not plain")
        #expect(try ItemNote.cleaned("   ") == nil)
    }

    @Test func notesStayShortCountedLikeTheDatabase() {
        #expect(throws: ItemNote.TooLong.self) { try ItemNote.cleaned(String(repeating: "x", count: 81)) }
        #expect(throws: ItemNote.TooLong.self) { try ItemNote.cleaned(String(repeating: "👨‍👩‍👧", count: 17)) }
    }

}

@MainActor
struct ItemNoteSyncTests {
    @Test func theNoteAndCategoryReachTheOfflineCache() async throws {
        let household = UUID(), item = UUID()
        let snapshot = SyncSnapshot(plan: nil, nights: [], listItems: [], items: [
            ItemRow(id: item, householdID: household, canonicalName: "Toothpaste", category: .personalCare,
                    keepOnHand: true, stockState: .low, note: "the bubblegum one")
        ])
        let container = try SyncService.inMemoryContainer()
        let service = SyncService(householdID: household, context: container.mainContext,
                                  client: .fake(snapshot: { snapshot }))
        await service.pull()
        let cached = try #require(try container.mainContext.fetch(FetchDescriptor<CachedItem>()).first)
        #expect(cached.note == "the bubblegum one")
        #expect(cached.category == .personalCare)
        #expect(cached.stockState == .low)
    }
}

@MainActor
struct ItemStoreTests {
    private let toothpaste = ItemDetails(id: UUID(), name: "Toothpaste", category: .personalCare, note: nil,
                                         keepOnHand: false)

    @Test func savingANoteSendsOnlyTheNoteForMembers() async {
        let sent = Mutex<ItemChanges?>(nil)
        let store = ItemStore(item: toothpaste, canRecategorize: false, client: ItemClient(update: { id, changes in
            #expect(id == toothpaste.id)
            sent.withLock { $0 = changes }
        }))
        store.note = " the bubblegum one "
        store.category = .household
        #expect(await store.save())
        #expect(sent.withLock { $0 } == ItemChanges(note: .some("the bubblegum one"), category: nil))
    }

    @Test func plannersCanRecategorize() async {
        let sent = Mutex<ItemChanges?>(nil)
        let store = ItemStore(item: toothpaste, canRecategorize: true, client: ItemClient(update: { _, changes in
            sent.withLock { $0 = changes }
        }))
        store.category = .household
        #expect(await store.save())
        #expect(sent.withLock { $0 } == ItemChanges(note: nil, category: .household))
    }

    @Test func nothingChangedSendsNothing() async {
        let store = ItemStore(item: toothpaste, canRecategorize: true, client: ItemClient(update: { _, _ in
            Issue.record("should not be called")
        }))
        #expect(await store.save())
    }

    @Test func clearingANoteSendsNull() async {
        let sent = Mutex<ItemChanges?>(nil)
        let noted = ItemDetails(id: UUID(), name: "Yogurt", category: .dairyEggs, note: "Vanilla", keepOnHand: false)
        let store = ItemStore(item: noted, canRecategorize: false, client: ItemClient(update: { _, changes in
            sent.withLock { $0 = changes }
        }))
        store.note = ""
        #expect(await store.save())
        #expect(sent.withLock { $0 } == ItemChanges(note: .some(nil), category: nil))
    }

    @Test func aTooLongNoteIsExplainedNotSent() async {
        let store = ItemStore(item: toothpaste, canRecategorize: false, client: ItemClient(update: { _, _ in
            Issue.record("should not be called")
        }))
        store.note = String(repeating: "x", count: 90)
        #expect(!(await store.save()))
        #expect(store.errorMessage == "Notes need 80 characters or fewer.")
    }

    @Test func keepOnHandIsQueuedEvenWhenTheNoteCannotBeSaved() async {
        let queued = Mutex<[Bool]>([])
        let store = ItemStore(item: toothpaste, canRecategorize: false,
                              client: ItemClient(update: { _, _ in throw URLError(.notConnectedToInternet) }),
                              queueStock: { keep in queued.withLock { $0.append(keep) } })
        store.keepOnHand = true
        store.note = "mint"
        #expect(!(await store.save()))
        #expect(queued.withLock { $0 } == [true], "the stock change works offline, so it goes through")
        #expect(store.errorMessage == "Keep on hand is saved. The note needs a connection; try again.")
        #expect(!(await store.save()))
        #expect(queued.withLock { $0 } == [true], "a retry doesn't queue it twice")
    }

    @Test func keepOnHandAloneNeedsNoConnection() async {
        let queued = Mutex<[Bool]>([])
        let store = ItemStore(item: toothpaste, canRecategorize: false,
                              client: ItemClient(update: { _, _ in Issue.record("should not be called") }),
                              queueStock: { keep in queued.withLock { $0.append(keep) } })
        store.keepOnHand = true
        #expect(await store.save())
        #expect(queued.withLock { $0 } == [true])
    }

    @Test func theSheetStartsFromTheOfflineCachesStock() {
        let store = ItemStore(item: toothpaste, canRecategorize: false, client: .preview, queueStock: { _ in })
        store.startFromCache(keepOnHand: true)
        #expect(store.keepOnHand)
        #expect(store.item.keepOnHand, "the cache is the baseline, so nothing is queued unless it changes")
    }

    @Test func aFailedSaveSaysSo() async {
        let store = ItemStore(item: toothpaste, canRecategorize: false, client: ItemClient(update: { _, _ in
            throw URLError(.notConnectedToInternet)
        }))
        store.note = "mint"
        #expect(!(await store.save()))
        #expect(store.errorMessage != nil)
    }

    @Test func theEncodedChangeHoldsOnlyWhatChanged() throws {
        let json = { (changes: ItemChanges) in
            String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)
        }
        #expect(try json(ItemChanges(note: .some(nil), category: nil)) == #"{"note":null}"#)
        #expect(try json(ItemChanges(note: nil, category: .household)) == #"{"category":"household"}"#)
    }
}
