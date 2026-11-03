import Foundation
import Testing
@testable import Foon

/// Receipt lines to the household's items (#61): noise dropped, abbreviations read, learned aliases first.
struct ReceiptMatcherTests {
    private let items = ReceiptFixtures.items

    /// Each line's text and its item's name, or "?" when it went under Didn't recognize.
    private func matches(_ receipt: [String], aliases: [ReceiptAlias] = []) -> [String: String] {
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
        let lines = ReceiptMatcher.match(receipt, items: items, aliases: aliases)
        return Dictionary(lines.map { ($0.text, $0.match.flatMap { names[$0.itemID] } ?? "?") },
                          uniquingKeysWith: { first, _ in first })
    }

    @Test func aWalmartReceiptReadsAsItsGroceries() {
        let found = matches(ReceiptFixtures.walmart)
        #expect(found == [
            "BANANAS": "Bananas",
            "GV WHL MILK": "Milk",
            "BNLS CHKN BRST": "Chicken breasts",
            "GV LG EGGS": "Eggs",
            "ORG BANANAS": "Bananas",
            "KRAFT MAC CHS": "Box mac and cheese",
            "BOUNTY PPR TWL": "Paper towels"
        ])
    }

    @Test func aKrogerReceiptDropsSavingsAndWeights() {
        let found = matches(ReceiptFixtures.kroger)
        #expect(found == [
            "CHOBANI YGRT": "Yogurt",
            "KRO SHRD CHDR": "Shredded cheddar",
            "STRWBRY": "Strawberries",
            "AVOCADOS HASS": "Avocados",
            "WT YEL ONIONS": "Onions",
            "KRO BTR SALTED": "Butter"
        ])
    }

    @Test func aTargetReceiptSkipsItsDepartmentsAndCodes() {
        let found = matches(ReceiptFixtures.target)
        #expect(found == [
            "GG SHRD MOZZ": "Shredded mozzarella",
            "GG BAGELS PLAIN": "Bagels",
            "APPLES HONEYCRISP": "Apples",
            "UP&UP DISH SOAP": "Dish soap"
        ])
    }

    @Test func aCostcoLineNobodyHasStaysUnrecognized() {
        let found = matches(ReceiptFixtures.costco)
        #expect(found == [
            "KS ORG EGGS": "Eggs",
            "KS PB CRMY": "Peanut butter",
            "CHERRY TOMATO": "Cherry tomatoes",
            "ROTISSERIE CHKN": "?"
        ])
    }

    @Test func aTraderJoesReceiptKeepsWhatItCouldNotPlace() {
        let found = matches(ReceiptFixtures.traderJoes)
        #expect(found == [
            "BANANA EACH": "Bananas",
            "SPAGHETTI ORGANIC": "Spaghetti",
            "MARINARA SAUCE": "Marinara sauce",
            "BABY SPINACH": "Spinach",
            "BAGGED SALAD": "?"
        ])
    }

    @Test func aSafewayReceiptReadsAWeighedLine() {
        let found = matches(ReceiptFixtures.safeway)
        #expect(found == [
            "LEMONS": "Lemons",
            "GRND BF": "Ground beef",
            "DIGIORNO PZA": "Frozen pizza"
        ])
    }

    @Test(arguments: [
        "SUBTOTAL 36.77", "TAX 1 6.750 % 1.08", "TOTAL 37.85", "VISA **** 4821", "CHANGE DUE 0.00", "2.04 lb @ 1 lb /0.58",
        "3 @ 0.29", "10/28/26 14:32:07", "(555) 555-0199", "ST# 01234 OP# 009012", "THANK YOU FOR SHOPPING",
        "1500 Elm Ave", "SPRINGFIELD OH 45501", "7.85 S", "MASTERCARD 20.54", "Card Savings 2.00-", "PRODUCE", "FROZEN"
    ])
    func noiseIsNeverACandidate(line: String) {
        #expect(ReceiptMatcher.candidates(["MILK 3.48", line]).map(\.text) == ["MILK"])
    }

    @Test func nothingAfterTheTotalIsAnItem() {
        let lines = ReceiptMatcher.candidates(["MILK 3.48", "TOTAL 3.48", "EGGS COUPON INSIDE"])
        #expect(lines.map(\.text) == ["MILK"])
    }

    @Test func headerLinesThatMatchNothingAreDropped() {
        let lines = ReceiptMatcher.match(["Save money. Live better.", "Fresh Market Grocer", "MILK 3.48"],
                                         items: items, aliases: [])
        #expect(lines.map(\.text) == ["MILK"])
    }

    @Test func withoutAnyPricedLineEveryLineIsKept() {
        // Vision can read the price column apart from the names: then nothing marks where the items start.
        let lines = ReceiptMatcher.match(["BAGGED SALAD", "MILK", "2.99", "3.48"], items: items, aliases: [])
        #expect(lines.map(\.text) == ["BAGGED SALAD", "MILK"])
    }

    @Test func theKeyIsTheLineWithoutPricesCodesOrFlags() {
        #expect(ReceiptMatcher.key("BNLS CHKN BRST 026080000000 9.97 N") == "bnls chkn brst")
        #expect(ReceiptMatcher.key("E 1234567 KS ORG EGGS 24 8.99") == "ks org eggs")
        #expect(ReceiptMatcher.key("  Strwbry   1LB $3.99 B ") == "strwbry")
        #expect(ReceiptMatcher.key("4.99") == nil)
    }

    @Test func aLearnedAliasComesFirst() {
        let thighs = ReceiptFixtures.item("Chicken thighs")
        let lines = ReceiptMatcher.match(["BNLS CHKN BRST 9.97"], items: items,
                                         aliases: [ReceiptAlias(rawText: "bnls chkn brst", itemID: thighs.id)])
        #expect(lines.first?.match == ReceiptMatcher.Match(itemID: thighs.id, confidence: 1, learned: true))
    }

    @Test func anAliasTeachesALineTheMatcherCouldNotPlace() {
        let salad = ReceiptItem(id: UUID(), name: "Salad greens")
        let lines = ReceiptMatcher.match(["BAGGED SALAD 2.99"], items: items + [salad],
                                         aliases: [ReceiptAlias(rawText: "bagged salad", itemID: salad.id)])
        #expect(lines.first?.match?.itemID == salad.id)
    }

    @Test func anAliasToAnItemTheHouseholdNoLongerHasIsIgnored() {
        let lines = ReceiptMatcher.match(["MILK 3.48"], items: items,
                                         aliases: [ReceiptAlias(rawText: "milk", itemID: UUID())])
        #expect(lines.first?.match?.itemID == ReceiptFixtures.item("Milk").id)
        #expect(lines.first?.match?.learned == false)
    }

    @Test func confidenceIsHigherForAnExactName() throws {
        let exact = try #require(ReceiptMatcher.match(["EGGS 4.12"], items: items, aliases: []).first?.match)
        let abbreviated = try #require(ReceiptMatcher.match(["STRWBRY 3.99"], items: items, aliases: []).first?.match)
        #expect(exact.confidence == 1)
        #expect(abbreviated.confidence < exact.confidence)
        #expect(abbreviated.confidence >= ReceiptMatcher.threshold)
    }

    @Test func aReadingSlipStillMatches() {
        #expect(matches(["BANANNAS 1.23"]) == ["BANANNAS": "Bananas"])
    }

    @Test func theSameInputGivesTheSameAnswer() {
        let first = ReceiptMatcher.match(ReceiptFixtures.walmart, items: items, aliases: [])
        let shuffledItems = ReceiptMatcher.match(ReceiptFixtures.walmart, items: items.reversed(), aliases: [])
        #expect(first == shuffledItems)
    }

    @Test func linesKeepTheirReceiptOrder() {
        let lines = ReceiptMatcher.match(ReceiptFixtures.kroger, items: items, aliases: [])
        #expect(lines.map(\.id) == Array(0..<lines.count))
        #expect(lines.first?.text == "CHOBANI YGRT")
    }
}
