import Foundation

/// One line on a shopping list, joined with its item, as the Lists tab and store mode show it.
struct ListEntry: Identifiable, Equatable, Sendable {
    let lineID: UUID
    let itemID: UUID
    let name: String
    let list: ListKind
    let urgency: ListUrgency
    /// The amounts the week's plan calls for.
    let quantity: String?
    /// This line's note: an allergy note from the plan, or why it's there.
    let lineNote: String?
    /// The item's standing note or brand preference.
    let itemNote: String?
    let category: ItemCategory
    let checkedAt: Date?
    let keepOnHand: Bool
    /// The item's line on the other list, shown in this row. An item has at most one open line per list, so a weekly line
    /// and a tonight line for the same milk read as one milk.
    var folded: [ListEntry] = []

    /// The item: a row is one per item, and keeps its place when a tonight line takes the lead from a weekly one.
    var id: UUID { itemID }

    /// Every line this row stands for: checking it off or removing it acts on all of them.
    var lineIDs: [UUID] { [lineID] + folded.map(\.lineID) }

    var hasQuickLine: Bool { list == .quick || folded.contains { $0.list == .quick } }

    static func entries(lines: [CachedListItem], items: [CachedItem]) -> [ListEntry] {
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lines.map { line in
            let item = itemsByID[line.itemID]
            return ListEntry(lineID: line.id, itemID: line.itemID, name: item?.name ?? line.itemName, list: line.list,
                             urgency: line.urgency, quantity: line.quantity, lineNote: line.note, itemNote: item?.note,
                             category: item?.category ?? .other, checkedAt: line.checkedAt,
                             keepOnHand: item?.keepOnHand ?? false)
        }
    }
}

/// A trip in progress: when it started and what was skipped ("couldn't find it"), kept across closing and
/// reopening store mode until Finish trip.
struct ShoppingTrip: Codable, Equatable, Sendable, RawRepresentable {
    var start: Date
    /// Quick-list lines made by "Couldn't find it" this trip: shown under For next time, not in the aisles.
    var skipped: Set<UUID> = []

    init(start: Date) {
        self.start = Date(timeIntervalSince1970: (start.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func storageKey(_ householdID: UUID) -> String { "foon.trip.\(householdID.uuidString)" }

    /// Whether a saved trip is still open for this household.
    static func inProgress(_ householdID: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: storageKey(householdID)).flatMap(ShoppingTrip.init(rawValue:)) != nil
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let trip = try? JSONDecoder().decode(ShoppingTrip.self, from: data) else { return nil }
        self = trip
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Field by field. Without this, RawRepresentable's `==` compares `rawValue` strings, and JSON key order isn't
    /// guaranteed, so the same trip could compare unequal to itself (#115).
    static func == (lhs: ShoppingTrip, rhs: ShoppingTrip) -> Bool {
        lhs.start == rhs.start && lhs.skipped == rhs.skipped
    }

    private enum CodingKeys: String, CodingKey { case start, skipped }

    /// The start is kept as whole milliseconds, so it reads back exactly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = Date(timeIntervalSince1970: Double(try container.decode(Int64.self, forKey: .start)) / 1000)
        skipped = try container.decodeIfPresent(Set<UUID>.self, forKey: .skipped) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int64((start.timeIntervalSince1970 * 1000).rounded()), forKey: .start)
        try container.encode(skipped.sorted { $0.uuidString < $1.uuidString }, forKey: .skipped)
    }
}

/// How the lists read: what's on them, staples running low, and store mode by aisle. Pure, from the offline
/// cache, so it all works with no signal in the store.
enum ListBoard {
    struct Staple: Identifiable, Equatable, Sendable {
        let itemID: UUID
        let name: String
        let state: StockState
        let category: ItemCategory

        var id: UUID { itemID }
    }

    struct Aisle: Identifiable, Equatable, Sendable {
        let category: ItemCategory
        let entries: [ListEntry]

        var id: ItemCategory { category }
    }

    struct Summary: Equatable, Sendable {
        let got: Int
        let left: Int
    }

    /// Open lines, one row per item: tonight's quick items first, then the weekly list, then the rest of the quick list.
    static func onTheList(_ entries: [ListEntry]) -> [ListEntry] {
        oneRowPerItem(entries.filter { $0.checkedAt == nil }).sorted { lhs, rhs in
            (rank(lhs), lhs.name.lowercased()) < (rank(rhs), rhs.name.lowercased())
        }
    }

    /// An item on both lists is one row: it takes the more urgent line's place, with every note, so it's bought once. Each
    /// line keeps its own amount, shown apart: two sixes might be the same eggs or twelve, and only the shopper can tell. The
    /// lines themselves stay apart, so undoing tonight's swap leaves the weekly list as it was.
    static func oneRowPerItem(_ entries: [ListEntry]) -> [ListEntry] {
        var order: [UUID] = []
        var byItem: [UUID: [ListEntry]] = [:]
        for entry in entries {
            if byItem[entry.itemID] == nil { order.append(entry.itemID) }
            byItem[entry.itemID, default: []].append(entry)
        }
        return order.compactMap { itemID in
            guard let lines = byItem[itemID]?.sorted(by: { rank($0) < rank($1) }), let first = lines.first else { return nil }
            guard lines.count > 1 else { return first }
            let rest = Array(lines.dropFirst())
            let note = rest.reduce(first.lineNote) { ListNotes.merged(existing: $0, incoming: $1.lineNote) }
            return ListEntry(lineID: first.lineID, itemID: itemID, name: first.name, list: first.list, urgency: first.urgency,
                             quantity: first.quantity, lineNote: note,
                             itemNote: first.itemNote, category: first.category,
                             checkedAt: lines.compactMap(\.checkedAt).max(), keepOnHand: first.keepOnHand, folded: rest)
        }
    }

    /// Staples marked low or out that aren't on a list yet: one tap puts them on.
    static func runningLow(_ staples: [Staple], open: [ListEntry]) -> [Staple] {
        let listed = Set(open.filter { $0.checkedAt == nil }.map(\.itemID))
        return staples.filter { $0.state != .in && !listed.contains($0.itemID) }
            .sorted { ($0.state == .out ? 0 : 1, $0.name.lowercased()) < ($1.state == .out ? 0 : 1, $1.name.lowercased()) }
    }

    /// Store mode: what's left by aisle in walking order (non-food last), what's in the cart this trip, and what
    /// was skipped for next time.
    static func store(_ entries: [ListEntry], tripStart: Date, skipped: Set<UUID> = [])
        -> (aisles: [Aisle], cart: [ListEntry], nextTime: [ListEntry]) {
        let rows = oneRowPerItem(entries.filter { $0.checkedAt == nil })
        let isSkipped = { (row: ListEntry) in row.lineIDs.contains(where: skipped.contains) }
        let open = rows.filter { !isSkipped($0) }
        let aisles = ItemCategory.storeOrder.compactMap { category -> Aisle? in
            let here = open.filter { $0.category == category }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            return here.isEmpty ? nil : Aisle(category: category, entries: here)
        }
        let cart = oneRowPerItem(entries.filter { ($0.checkedAt ?? .distantPast) >= tripStart })
            .sorted { ($0.checkedAt ?? .distantPast) > ($1.checkedAt ?? .distantPast) }
        let nextTime = rows.filter(isSkipped)
        return (aisles, cart, nextTime)
    }

    static func summary(_ entries: [ListEntry], tripStart: Date, skipped: Set<UUID> = []) -> Summary {
        let board = store(entries, tripStart: tripStart, skipped: skipped)
        return Summary(got: board.cart.count, left: board.aisles.reduce(0) { $0 + $1.entries.count })
    }

    /// Checking off a row checks off every line in it; a staple bought goes back to in stock at once, so it doesn't pop up as
    /// running low.
    static func gotIt(_ entry: ListEntry) -> [OfflineChange] {
        entry.lineIDs.map { .setChecked(listItemID: $0, checked: true) }
            + (entry.keepOnHand ? [.setStock(itemID: entry.itemID, state: .in)] : [])
    }

    /// Putting a cart row back reopens its latest line on each list. A list holds one open line per item, so an older one
    /// bought this trip (milk bought, marked out again, bought again) stays bought.
    static func putBack(_ entry: ListEntry) -> [OfflineChange] {
        let latest = Dictionary(([entry] + entry.folded).map { ($0.list, $0) }) { lhs, rhs in
            (lhs.checkedAt ?? .distantPast) >= (rhs.checkedAt ?? .distantPast) ? lhs : rhs
        }
        return entry.lineIDs.filter { id in latest.values.contains { $0.lineID == id } }
            .map { .setChecked(listItemID: $0, checked: false) }
    }

    static func remove(_ entry: ListEntry) -> [OfflineChange] {
        entry.lineIDs.map { .removeFromList(listItemID: $0) }
    }

    /// What "Couldn't find it" sets aside for next time: the row's lines when it's on the quick list already, or else the
    /// quick line it's about to move to.
    static func skippedLines(_ entry: ListEntry, newLineID: UUID) -> [UUID] {
        entry.hasQuickLine ? entry.lineIDs : [newLineID]
    }

    /// "Couldn't find it": the item moves to the quick list for the next trip, with its amount and any allergy note. A row
    /// with a quick line is already there; its weekly line stays put rather than lose its amount in the merge.
    static func couldntFind(_ entry: ListEntry, householdID: UUID, newLineID: UUID) -> [OfflineChange] {
        guard !entry.hasQuickLine else { return [] }
        return [
            .addToList(householdID: householdID, itemID: entry.itemID, list: .quick, urgency: .whenever,
                       source: .manual,
                       note: ListNotes.merged(existing: entry.lineNote, incoming: String(localized: "Couldn't find it last trip")),
                       lineID: newLineID, quantity: entry.quantity, replacing: entry.lineID)
        ]
    }

    private static func rank(_ entry: ListEntry) -> Int {
        switch (entry.list, entry.urgency) {
        case (.quick, .tonight): 0
        case (.weekly, _): 1
        case (.quick, .whenever): 2
        }
    }
}
