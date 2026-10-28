import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

struct ListBoardTests {
    private let tripStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, list: ListKind = .weekly, urgency: ListUrgency = .whenever,
                       category: ItemCategory = .pantry, checkedAt: Date? = nil, keepOnHand: Bool = false) -> ListEntry {
        ListEntry(lineID: UUID(), itemID: UUID(), name: name, list: list, urgency: urgency, quantity: nil,
                  lineNote: nil, itemNote: nil, category: category, checkedAt: checkedAt, keepOnHand: keepOnHand)
    }

    @Test func onTheListPutsTonightFirstThenTheWeekThenTheRest() {
        let entries = [entry("Apples", list: .quick), entry("Beef"), entry("Milk", list: .quick, urgency: .tonight),
                       entry("Bread"), entry("Eggs", checkedAt: tripStart)]
        #expect(ListBoard.onTheList(entries).map(\.name) == ["Milk", "Beef", "Bread", "Apples"])
    }

    @Test func staplesRunningLowSkipWhatsAlreadyOnAList() {
        let cereal = ListBoard.Staple(itemID: UUID(), name: "Cereal", state: .out, category: .pantry)
        let rice = ListBoard.Staple(itemID: UUID(), name: "Rice", state: .low, category: .pantry)
        let flour = ListBoard.Staple(itemID: UUID(), name: "Flour", state: .in, category: .pantry)
        var listed = entry("Rice")
        listed = ListEntry(lineID: listed.lineID, itemID: rice.itemID, name: "Rice", list: .weekly, urgency: .whenever,
                           quantity: nil, lineNote: nil, itemNote: nil, category: .pantry, checkedAt: nil, keepOnHand: true)
        #expect(ListBoard.runningLow([cereal, rice, flour], open: [listed]).map(\.name) == ["Cereal"])
    }

    @Test func storeModeGroupsByAisleWithNonFoodLast() {
        let entries = [entry("Paper towels", category: .household), entry("Bananas", category: .produce),
                       entry("Toothpaste", category: .personalCare), entry("Milk", category: .dairyEggs),
                       entry("Apples", category: .produce)]
        let board = ListBoard.store(entries, tripStart: tripStart)
        #expect(board.aisles.map(\.category) == [.produce, .dairyEggs, .household, .personalCare])
        #expect(board.aisles[0].entries.map(\.name) == ["Apples", "Bananas"])
    }

    @Test func checkedItemsSinkIntoTheCartForThisTripOnly() {
        let entries = [entry("Milk", category: .dairyEggs, checkedAt: tripStart.addingTimeInterval(60)),
                       entry("Bread", category: .bakery),
                       entry("Old", checkedAt: tripStart.addingTimeInterval(-3600))]
        let board = ListBoard.store(entries, tripStart: tripStart)
        #expect(board.aisles.flatMap(\.entries).map(\.name) == ["Bread"])
        #expect(board.cart.map(\.name) == ["Milk"], "yesterday's check-offs aren't this trip's cart")
    }

    @Test func aTripSummaryCountsWhatWasGotAndWhatsLeft() {
        let entries = [entry("Milk", checkedAt: tripStart.addingTimeInterval(5)), entry("Bread"), entry("Eggs")]
        #expect(ListBoard.summary(entries, tripStart: tripStart) == ListBoard.Summary(got: 1, left: 2))
    }

    @Test func finishingATripRestocksTheStaplesBought() {
        let cereal = entry("Cereal", checkedAt: tripStart.addingTimeInterval(5), keepOnHand: true)
        let milk = entry("Milk", checkedAt: tripStart.addingTimeInterval(5))
        let rice = entry("Rice", keepOnHand: true)
        #expect(ListBoard.finishTrip([cereal, milk, rice], tripStart: tripStart)
            == [.setStock(itemID: cereal.itemID, state: .in)])
    }

    @Test func aTripSurvivesBeingSavedAndReopened() throws {
        var trip = ShoppingTrip(start: tripStart)
        trip.skipped.insert(UUID())
        let restored = try #require(ShoppingTrip(rawValue: trip.rawValue))
        #expect(restored == trip)
        #expect(restored.rawValue == trip.rawValue, "the stored form is stable, keys sorted")
        #expect(ShoppingTrip(rawValue: "") == nil)
    }

    @Test func equalTripsAreEqualWhateverOrderTheirJSONKeysCameIn() throws {
        let skipped = UUID()
        let startFirst = try #require(ShoppingTrip(rawValue: #"{"start":1800000000000,"skipped":["\#(skipped)"]}"#))
        let skippedFirst = try #require(ShoppingTrip(rawValue: #"{"skipped":["\#(skipped)"],"start":1800000000000}"#))
        #expect(startFirst == skippedFirst)
    }

    @Test func skippedItemsLeaveTheAislesForNextTime() {
        let saffron = entry("Saffron", list: .quick, category: .pantry)
        let rice = entry("Rice", category: .pantry)
        let board = ListBoard.store([saffron, rice], tripStart: tripStart, skipped: [saffron.lineID])
        #expect(board.aisles.flatMap(\.entries).map(\.name) == ["Rice"])
        #expect(board.nextTime.map(\.name) == ["Saffron"])
        #expect(ListBoard.summary([saffron, rice], tripStart: tripStart, skipped: [saffron.lineID])
            == ListBoard.Summary(got: 0, left: 1))
    }

    @Test func gettingAStapleRestocksIt() {
        let cereal = entry("Cereal", keepOnHand: true)
        #expect(ListBoard.gotIt(cereal) == [.setChecked(listItemID: cereal.lineID, checked: true),
                                            .setStock(itemID: cereal.itemID, state: .in)])
        let milk = entry("Milk")
        #expect(ListBoard.gotIt(milk) == [.setChecked(listItemID: milk.lineID, checked: true)])
    }

    @Test func couldntFindItMovesTheItemToTheQuickList() {
        let beef = entry("Beef")
        let household = UUID(), quickLine = UUID()
        #expect(ListBoard.couldntFind(beef, householdID: household, newLineID: quickLine) == [
            .addToList(householdID: household, itemID: beef.itemID, list: .quick, urgency: .whenever, source: .manual,
                       note: String(localized: "Couldn't find it last trip"), lineID: quickLine),
            .removeFromList(listItemID: beef.lineID)
        ])
        let quick = entry("Saffron", list: .quick)
        #expect(ListBoard.couldntFind(quick, householdID: household, newLineID: quickLine).isEmpty,
                "already on the quick list")
    }
}

@MainActor
struct ListSyncTests {
    private let household = UUID(), milkItem = UUID(), milkLine = UUID()

    nonisolated private var snapshot: SyncSnapshot {
        SyncSnapshot(plan: nil, nights: [],
                     listItems: [ListItemRow(id: milkLine, householdID: household, itemID: milkItem, list: .weekly,
                                             urgency: .whenever, source: .plan, note: "Get dairy-free (Nora)",
                                             checkedAt: nil, quantity: "1 gallon")],
                     items: [ItemRow(id: milkItem, householdID: household, canonicalName: "Milk", category: .dairyEggs,
                                     keepOnHand: false, stockState: nil, note: "Whole")])
    }

    @Test func removingALineWorksOfflineAndSyncsLater() async throws {
        let container = try SyncService.inMemoryContainer()
        let online = Mutex(false)
        let sent = Mutex<[OfflineChange]>([])
        let service = SyncService(householdID: household, context: container.mainContext, client: .fake(
            snapshot: { snapshot },
            send: { change in
                guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                sent.withLock { $0.append(change) }
            }
        ))
        await service.pull()
        await service.perform(.removeFromList(listItemID: milkLine))
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).isEmpty)
        online.withLock { $0 = true }
        await service.replayPending()
        #expect(sent.withLock { $0 } == [.removeFromList(listItemID: milkLine)])
    }

    @Test func entriesJoinLinesWithTheirItems() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = SyncService(householdID: household, context: container.mainContext,
                                  client: .fake(snapshot: { snapshot }))
        await service.pull()
        let lines = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        let items = try container.mainContext.fetch(FetchDescriptor<CachedItem>())
        let entries = ListEntry.entries(lines: lines, items: items)
        #expect(entries.first?.name == "Milk")
        #expect(entries.first?.quantity == "1 gallon")
        #expect(entries.first?.itemNote == "Whole")
        #expect(entries.first?.lineNote == "Get dairy-free (Nora)")
        #expect(entries.first?.category == .dairyEggs)
    }
}
