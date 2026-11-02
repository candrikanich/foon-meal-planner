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

    @Test func gettingAStapleRestocksItFromTheStockThisPhoneSaw() {
        var cereal = entry("Cereal", keepOnHand: true)
        cereal.stock = .low
        #expect(ListBoard.gotIt(cereal) == [.setChecked(listItemID: cereal.lineID, checked: true),
                                            .restock(itemID: cereal.itemID, ifWas: .low)])
        let milk = entry("Milk")
        #expect(ListBoard.gotIt(milk) == [.setChecked(listItemID: milk.lineID, checked: true),
                                          .restock(itemID: milk.itemID, ifWas: nil)],
                "another phone may have made it a staple; the server decides")
    }

    @Test func couldntFindItMovesTheItemToTheQuickList() {
        let beef = entry("Beef")
        let household = UUID(), quickLine = UUID()
        #expect(ListBoard.couldntFind(beef, householdID: household, newLineID: quickLine) == [
            .addToList(householdID: household, itemID: beef.itemID, list: .quick, urgency: .whenever, source: .manual,
                       note: String(localized: "Couldn't find it last trip"), lineID: quickLine, replacing: beef.lineID)
        ], "one change, so a refused add can't still remove the line")
        let quick = entry("Saffron", list: .quick)
        #expect(ListBoard.couldntFind(quick, householdID: household, newLineID: quickLine).isEmpty,
                "already on the quick list")
    }

    private func milk(_ list: ListKind, urgency: ListUrgency = .whenever, quantity: String? = nil, note: String? = nil,
                      checkedAt: Date? = nil, item: UUID) -> ListEntry {
        ListEntry(lineID: UUID(), itemID: item, name: "milk", list: list, urgency: urgency, quantity: quantity,
                  lineNote: note, itemNote: nil, category: .dairyEggs, checkedAt: checkedAt, keepOnHand: true)
    }

    @Test func anItemOnBothListsIsOneRow() throws {
        let item = UUID()
        let weekly = milk(.weekly, quantity: "1 gallon", note: "Get dairy-free (Nora)", item: item)
        let tonight = milk(.quick, urgency: .tonight, quantity: "2 cups", item: item)
        let rows = ListBoard.onTheList([weekly, entry("Bread"), tonight])
        #expect(rows.map(\.name) == ["milk", "Bread"], "it reads as tonight's")
        let row = try #require(rows.first)
        #expect(row.lineID == tonight.lineID)
        #expect(Set(row.lineIDs) == [weekly.lineID, tonight.lineID])
        #expect(row.quantity == "2 cups", "each line keeps its own amount")
        #expect(row.folded.map(\.quantity) == ["1 gallon"])
        #expect(row.id == item, "the row keeps its place when a tonight line takes the lead")
        #expect(row.lineNote == "Get dairy-free (Nora)", "an allergy note on either line shows")
    }

    @Test func equalAmountsAreBothShown() throws {
        // Monday's 6 eggs and tonight's frittata's 6 might be twelve: neither is dropped, and they aren't added up.
        let item = UUID()
        let row = try #require(ListBoard.onTheList([milk(.weekly, quantity: "6", item: item),
                                                    milk(.quick, urgency: .tonight, quantity: "6", item: item)]).first)
        #expect(row.quantity == "6")
        #expect(row.folded.map(\.quantity) == ["6"])
    }

    @Test func puttingBackReopensOnlyTheLatestLineOnEachList() throws {
        let item = UUID()
        let first = milk(.quick, checkedAt: tripStart.addingTimeInterval(5), item: item)
        let again = milk(.quick, checkedAt: tripStart.addingTimeInterval(60), item: item)
        let weekly = milk(.weekly, checkedAt: tripStart.addingTimeInterval(30), item: item)
        let row = try #require(ListBoard.store([first, again, weekly], tripStart: tripStart).cart.first)
        let changes = ListBoard.putBack(row)
        #expect(changes.count == 2, "a list holds one open line per item")
        #expect(changes.contains(.setChecked(listItemID: again.lineID, checked: false)))
        #expect(changes.contains(.setChecked(listItemID: weekly.lineID, checked: false)))
    }

    @Test func checkingOffOrRemovingTheRowActsOnBothLines() throws {
        let item = UUID()
        let weekly = milk(.weekly, item: item), tonight = milk(.quick, urgency: .tonight, item: item)
        let row = try #require(ListBoard.onTheList([weekly, tonight]).first)
        #expect(ListBoard.gotIt(row) == [.setChecked(listItemID: tonight.lineID, checked: true),
                                         .setChecked(listItemID: weekly.lineID, checked: true),
                                         .restock(itemID: item, ifWas: nil)])
        #expect(ListBoard.putBack(row) == [.setChecked(listItemID: tonight.lineID, checked: false),
                                           .setChecked(listItemID: weekly.lineID, checked: false)])
        #expect(ListBoard.remove(row) == [.removeFromList(listItemID: tonight.lineID),
                                          .removeFromList(listItemID: weekly.lineID)])
    }

    @Test func storeModeShowsTheItemOnceInTheAisleAndInTheCart() {
        let item = UUID()
        let open = [milk(.weekly, item: item), milk(.quick, urgency: .tonight, item: item)]
        #expect(ListBoard.store(open, tripStart: tripStart).aisles.flatMap(\.entries).count == 1)
        let bought = [milk(.weekly, checkedAt: tripStart.addingTimeInterval(5), item: item),
                      milk(.quick, urgency: .tonight, checkedAt: tripStart.addingTimeInterval(5), item: item)]
        #expect(ListBoard.store(bought, tripStart: tripStart).cart.count == 1)
        #expect(ListBoard.summary(bought + [entry("Bread")], tripStart: tripStart) == ListBoard.Summary(got: 1, left: 1))
    }

    @Test func couldntFindARowWithAQuickLineSetsTheWholeRowAside() throws {
        let item = UUID(), household = UUID(), newLine = UUID()
        let weekly = milk(.weekly, quantity: "1 gallon", item: item), quick = milk(.quick, quantity: "2 cups", item: item)
        let row = try #require(ListBoard.onTheList([weekly, quick]).first)
        #expect(row.list == .weekly, "the weekly line ranks above a quick one that isn't for tonight")
        #expect(ListBoard.couldntFind(row, householdID: household, newLineID: newLine).isEmpty,
                "the weekly line keeps its amount rather than merging into the quick line's")
        let skipped = Set(ListBoard.skippedLines(row, newLineID: newLine))
        #expect(skipped == [weekly.lineID, quick.lineID])
        let board = ListBoard.store([weekly, quick], tripStart: tripStart, skipped: skipped)
        #expect(board.aisles.isEmpty)
        #expect(board.nextTime.map(\.lineID) == [weekly.lineID])
        #expect(ListBoard.skippedLines(entry("Beef"), newLineID: newLine) == [newLine])
    }

    @Test func differentItemsWithTheSameNameStayApart() {
        #expect(ListBoard.onTheList([milk(.weekly, item: UUID()), milk(.quick, item: UUID())]).count == 2)
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
