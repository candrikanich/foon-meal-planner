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

    var id: UUID { lineID }

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
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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

    /// Open lines: tonight's quick items first, then the weekly list, then the rest of the quick list.
    static func onTheList(_ entries: [ListEntry]) -> [ListEntry] {
        entries.filter { $0.checkedAt == nil }.sorted { lhs, rhs in
            (rank(lhs), lhs.name.lowercased()) < (rank(rhs), rhs.name.lowercased())
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
        let open = entries.filter { $0.checkedAt == nil && !skipped.contains($0.lineID) }
        let aisles = ItemCategory.storeOrder.compactMap { category -> Aisle? in
            let here = open.filter { $0.category == category }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            return here.isEmpty ? nil : Aisle(category: category, entries: here)
        }
        let cart = entries.filter { ($0.checkedAt ?? .distantPast) >= tripStart }
            .sorted { ($0.checkedAt ?? .distantPast) > ($1.checkedAt ?? .distantPast) }
        let nextTime = entries.filter { $0.checkedAt == nil && skipped.contains($0.lineID) }
        return (aisles, cart, nextTime)
    }

    static func summary(_ entries: [ListEntry], tripStart: Date, skipped: Set<UUID> = []) -> Summary {
        Summary(got: entries.filter { ($0.checkedAt ?? .distantPast) >= tripStart }.count,
                left: entries.filter { $0.checkedAt == nil && !skipped.contains($0.lineID) }.count)
    }

    /// Checking off a line; a staple bought goes back to in stock at once, so it doesn't pop up as running low.
    static func gotIt(_ entry: ListEntry) -> [OfflineChange] {
        [.setChecked(listItemID: entry.lineID, checked: true)]
            + (entry.keepOnHand ? [.setStock(itemID: entry.itemID, state: .in)] : [])
    }

    /// Finishing a trip: staples bought go back to in stock.
    static func finishTrip(_ entries: [ListEntry], tripStart: Date) -> [OfflineChange] {
        let bought = entries.filter { $0.keepOnHand && ($0.checkedAt ?? .distantPast) >= tripStart }
        return Array(Set(bought.map(\.itemID))).sorted { $0.uuidString < $1.uuidString }
            .map { .setStock(itemID: $0, state: .in) }
    }

    /// "Couldn't find it": the item moves to the quick list for the next trip.
    static func couldntFind(_ entry: ListEntry, householdID: UUID, newLineID: UUID) -> [OfflineChange] {
        guard entry.list != .quick else { return [] }
        return [
            .addToList(householdID: householdID, itemID: entry.itemID, list: .quick, urgency: .whenever,
                       source: .manual, note: String(localized: "Couldn't find it last trip"), lineID: newLineID),
            .removeFromList(listItemID: entry.lineID)
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
