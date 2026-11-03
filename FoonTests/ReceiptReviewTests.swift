import Foundation
import Testing
@testable import Foon

/// Reviewing a scanned receipt before anything changes, and what Confirm does (#61).
struct ReceiptReviewTests {
    private let household = UUID(uuidString: "00000000-0000-0000-0000-0000000000a0")!
    private let milk = ReceiptFixtures.item("Milk")
    private let eggs = ReceiptFixtures.item("Eggs")
    private let bananas = ReceiptFixtures.item("Bananas")
    private let thighs = ReceiptFixtures.item("Chicken thighs")

    private func review(_ receipt: [String], aliases: [ReceiptAlias] = []) -> ReceiptReview {
        ReceiptReview(ReceiptMatcher.match(receipt, items: ReceiptFixtures.items, aliases: aliases))
    }

    @Test func matchedLinesAreIncludedAndUnrecognizedOnesSkipped() {
        let review = review(["MILK 3.48", "BAGGED SALAD 2.99"])
        #expect(review.matched.map(\.text) == ["MILK"])
        #expect(review.unrecognized.map(\.text) == ["BAGGED SALAD"])
        #expect(review.matched.first?.isIncluded == true)
        #expect(review.unrecognized.first?.isIncluded == false)
        #expect(review.itemIDs == [milk.id])
    }

    @Test func assigningAnUnrecognizedLineIncludesItAndTeachesIt() throws {
        var review = review(["MILK 3.48", "BAGGED SALAD 2.99"])
        let salad = try #require(review.unrecognized.first)
        review.assign(salad.id, to: eggs.id)
        #expect(review.itemIDs == [milk.id, eggs.id])
        #expect(review.corrections == [ReceiptAlias(rawText: "bagged salad", itemID: eggs.id)])
        #expect(review.unrecognized.map(\.text) == ["BAGGED SALAD"], "it stays where it was listed")
    }

    @Test func changingAMatchTeachesTheNewItem() throws {
        var review = review(["BNLS CHKN BRST 9.97"])
        let line = try #require(review.matched.first)
        review.assign(line.id, to: thighs.id)
        #expect(review.itemIDs == [thighs.id])
        #expect(review.corrections == [ReceiptAlias(rawText: "bnls chkn brst", itemID: thighs.id)])
    }

    @Test func keepingTheMatchTeachesNothing() {
        let review = review(["MILK 3.48", "EGGS 4.12"])
        #expect(review.corrections.isEmpty)
    }

    @Test func choosingTheSuggestedItemAgainIsNotACorrection() throws {
        var review = review(["MILK 3.48"])
        let line = try #require(review.matched.first)
        review.assign(line.id, to: eggs.id)
        review.assign(line.id, to: milk.id)
        #expect(review.corrections.isEmpty)
    }

    @Test func aSkippedLineChangesNothingAndTeachesNothing() throws {
        var review = review(["BNLS CHKN BRST 9.97", "MILK 3.48"])
        let chicken = try #require(review.matched.first)
        review.assign(chicken.id, to: thighs.id)
        review.setIncluded(chicken.id, false)
        #expect(review.itemIDs == [milk.id])
        #expect(review.corrections.isEmpty)
        review.setIncluded(chicken.id, true)
        #expect(review.itemIDs == [thighs.id, milk.id])
    }

    @Test func anUnrecognizedLineCannotBeIncludedWithoutAnItem() throws {
        var review = review(["BAGGED SALAD 2.99"])
        let line = try #require(review.unrecognized.first)
        review.setIncluded(line.id, true)
        #expect(review.unrecognized.first?.isIncluded == false)
    }

    @Test func twoLinesForOneItemCountOnce() {
        let review = review(["BANANAS 1.23", "ORG BANANAS 0.88"])
        #expect(review.itemIDs == [bananas.id])
    }

    @Test func aLearnedLineIsNotTaughtAgain() {
        let review = review(["BNLS CHKN BRST 9.97"], aliases: [ReceiptAlias(rawText: "bnls chkn brst", itemID: thighs.id)])
        #expect(review.itemIDs == [thighs.id])
        #expect(review.corrections.isEmpty)
    }
}

/// What Confirm sends through the sync queue.
struct ReceiptApplyTests {
    private let household = UUID()

    private func entry(_ item: UUID, list: ListKind = .quick, line: UUID = UUID(), keepOnHand: Bool = false,
                       stock: StockState? = nil, checked: Date? = nil) -> ListEntry {
        ListEntry(lineID: line, itemID: item, name: "Item", list: list, urgency: .whenever, quantity: nil, lineNote: nil,
                  itemNote: nil, category: .other, checkedAt: checked, keepOnHand: keepOnHand, stock: stock)
    }

    @Test func anItemOnTheListsIsCheckedOffEverywhereAndRestocked() {
        let milk = UUID(), weekly = UUID(), quick = UUID()
        let entries = [entry(milk, list: .weekly, line: weekly, keepOnHand: true, stock: .low),
                       entry(milk, list: .quick, line: quick, keepOnHand: true, stock: .low)]
        let changes = ReceiptApply.changes(itemIDs: [milk], entries: entries,
                                           stock: [milk: ReceiptStock(keepOnHand: true, state: .low)],
                                           corrections: [], householdID: household)
        #expect(changes == [.setChecked(listItemID: weekly, checked: true), .setChecked(listItemID: quick, checked: true),
                            .restock(itemID: milk, ifWas: .low)])
    }

    @Test func aStapleNotOnAListFlipsToIn() {
        let cereal = UUID()
        let changes = ReceiptApply.changes(itemIDs: [cereal], entries: [],
                                           stock: [cereal: ReceiptStock(keepOnHand: true, state: .out)],
                                           corrections: [], householdID: household)
        #expect(changes == [.restock(itemID: cereal, ifWas: .out)])
    }

    @Test func aStapleAlreadyInAndNotListedNeedsNothing() {
        let cereal = UUID()
        let changes = ReceiptApply.changes(itemIDs: [cereal], entries: [],
                                           stock: [cereal: ReceiptStock(keepOnHand: true, state: .in)],
                                           corrections: [], householdID: household)
        #expect(changes.isEmpty)
    }

    @Test func anItemThatIsNeitherListedNorAStapleNeedsNothing() {
        let candy = UUID()
        let changes = ReceiptApply.changes(itemIDs: [candy], entries: [], stock: [:], corrections: [], householdID: household)
        #expect(changes.isEmpty)
    }

    @Test func aLineAlreadyCheckedOffIsLeftAlone() {
        let milk = UUID()
        let changes = ReceiptApply.changes(itemIDs: [milk], entries: [entry(milk, checked: .now)], stock: [:],
                                           corrections: [], householdID: household)
        #expect(changes.isEmpty)
    }

    @Test func correctionsAreTaughtAfterTheCheckOffs() {
        let milk = UUID(), line = UUID()
        let alias = ReceiptAlias(rawText: "gv whl mlk", itemID: milk)
        let changes = ReceiptApply.changes(itemIDs: [milk], entries: [entry(milk, line: line)], stock: [:],
                                           corrections: [alias], householdID: household)
        #expect(changes.last == .teachReceiptAlias(householdID: household, rawText: "gv whl mlk", itemID: milk))
        #expect(changes.first == .setChecked(listItemID: line, checked: true))
    }
}

/// "Keep apples on hand?" after a receipt (#61).
struct ReceiptStaplesTests {
    private let apples = UUID(), milk = UUID(), candy = UUID(), soap = UUID(), eggs = UUID(), bread = UUID()

    @Test func anItemBoughtBeforeThatIsNotAStapleIsOffered() {
        let offered = ReceiptStaples.suggestions(
            bought: [apples, milk, candy],
            stock: [milk: ReceiptStock(keepOnHand: true, state: .in)],
            boughtBefore: [apples, milk]
        )
        #expect(offered == [apples])
    }

    @Test func atMostThreeAreOfferedInReceiptOrder() {
        let all = [apples, milk, candy, soap, eggs]
        let offered = ReceiptStaples.suggestions(bought: all, stock: [:], boughtBefore: Set(all))
        #expect(offered == [apples, milk, candy])
    }

    @Test func nothingBoughtBeforeMeansNothingOffered() {
        #expect(ReceiptStaples.suggestions(bought: [apples, bread], stock: [:], boughtBefore: []).isEmpty)
    }

    @Test func theWindowIsThirtyDaysEndingADayAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = ReceiptStaples.window(endingAt: now)
        #expect(window.lowerBound == now.addingTimeInterval(-30 * 86_400))
        #expect(window.upperBound == now.addingTimeInterval(-86_400))
    }
}
