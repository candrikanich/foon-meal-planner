import Foundation

/// A scanned receipt being checked before anything changes: each line with the item it's taken as, which can be changed,
/// and whether it counts. Matched lines count unless skipped; lines the matcher couldn't place are skipped until someone
/// gives them an item. Nothing reaches the lists or the stock until Confirm.
struct ReceiptReview: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let key: String
        /// What the matcher (or a learned alias) said.
        let suggested: ReceiptMatcher.Match?
        /// What it's taken as now.
        var itemID: UUID?
        var isIncluded: Bool
    }

    private(set) var rows: [Row]

    init(_ lines: [ReceiptMatcher.Line]) {
        rows = lines.map { line in
            Row(id: line.id, text: line.text, key: line.key, suggested: line.match, itemID: line.match?.itemID,
                isIncluded: line.match != nil)
        }
    }

    /// Lines the matcher placed, in receipt order.
    var matched: [Row] { rows.filter { $0.suggested != nil } }
    /// "Didn't recognize": where they were listed, even once assigned, so they don't jump about.
    var unrecognized: [Row] { rows.filter { $0.suggested == nil } }

    mutating func assign(_ rowID: Int, to itemID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].itemID = itemID
        rows[index].isIncluded = true
    }

    /// A line without an item can't count.
    mutating func setIncluded(_ rowID: Int, _ included: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].isIncluded = included && rows[index].itemID != nil
    }

    /// The items bought, once each, in receipt order.
    var itemIDs: [UUID] {
        var seen = Set<UUID>()
        return rows.filter(\.isIncluded).compactMap(\.itemID).filter { seen.insert($0).inserted }
    }

    /// Lines that count and were given a different item than suggested: what the household learns.
    var corrections: [ReceiptAlias] {
        rows.compactMap { row in
            guard row.isIncluded, let itemID = row.itemID, itemID != row.suggested?.itemID else { return nil }
            return ReceiptAlias(rawText: row.key, itemID: itemID)
        }
    }
}

/// A staple's stock as this phone has it.
struct ReceiptStock: Equatable, Sendable {
    let keepOnHand: Bool
    let state: StockState?
}

/// What Confirm does, as changes for the sync queue so it works offline (docs/spec.md → Pantry state without counting:
/// "Receipt scanned: items count as on hand and staples flip to in").
enum ReceiptApply {
    /// Each item's open lines are checked off, as Got it does, which also restocks a staple. A staple bought that wasn't on
    /// a list goes back to in. Then the corrections are taught.
    static func changes(itemIDs: [UUID], entries: [ListEntry], stock: [UUID: ReceiptStock],
                        corrections: [ReceiptAlias], householdID: UUID) -> [OfflineChange] {
        let rows = Dictionary(ListBoard.oneRowPerItem(entries.filter { $0.checkedAt == nil }).map { ($0.itemID, $0) },
                              uniquingKeysWith: { first, _ in first })
        let bought = itemIDs.flatMap { itemID -> [OfflineChange] in
            if let row = rows[itemID] { return ListBoard.gotIt(row) }
            guard let staple = stock[itemID], staple.keepOnHand, let state = staple.state, state != .in else { return [] }
            return [.restock(itemID: itemID, ifWas: state)]
        }
        let taught = corrections.map {
            OfflineChange.teachReceiptAlias(householdID: householdID, rawText: $0.rawText, itemID: $0.itemID)
        }
        return bought + taught
    }
}

/// "Keep apples on hand?" after a receipt. No receipts are kept, so "bought before" is the list's history: an item that
/// isn't a staple yet, bought on this receipt, and checked off a list on an earlier trip in the last 30 days.
enum ReceiptStaples {
    static let limit = 3
    static let lookback: TimeInterval = 30 * 86_400
    /// Today's trip doesn't count as an earlier one.
    static let sameTrip: TimeInterval = 86_400

    static func window(endingAt now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-lookback)...now.addingTimeInterval(-sameTrip)
    }

    static func suggestions(bought: [UUID], stock: [UUID: ReceiptStock], boughtBefore: Set<UUID>) -> [UUID] {
        Array(bought.filter { boughtBefore.contains($0) && stock[$0]?.keepOnHand != true }.prefix(limit))
    }
}
