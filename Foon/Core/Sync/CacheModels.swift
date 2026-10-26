import Foundation
import SwiftData

// The on-device cache (SwiftData) for the current week and the lists, so store mode works without
// signal. Each pull replaces the household's rows; enum values are stored as their raw strings.

@Model
final class CachedPlan {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var weekStart: String
    var approvedAt: Date?

    init(_ row: PlanRow) {
        id = row.id
        householdID = row.householdID
        weekStart = row.weekStart.isoString
        approvedAt = row.approvedAt
    }
}

@Model
final class CachedNight {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var planID: UUID
    var date: String
    var effortRaw: String
    var dinnerTime: String?
    var mealID: UUID?
    var mealName: String?
    var quickPickRaw: String?
    var locked: Bool

    init(_ row: NightRow, householdID: UUID) {
        id = row.id
        self.householdID = householdID
        planID = row.planID
        date = row.date.isoString
        effortRaw = row.effort.rawValue
        dinnerTime = row.dinnerTime
        mealID = row.mealID
        mealName = row.mealName
        quickPickRaw = row.quickPick?.rawValue
        locked = row.locked
    }

    var effort: NightEffort { NightEffort(rawValue: effortRaw) ?? .normal }
    var quickPick: QuickPick? { quickPickRaw.flatMap(QuickPick.init(rawValue:)) }
}

@Model
final class CachedListItem {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var itemID: UUID
    var itemName: String
    var listRaw: String
    var urgencyRaw: String
    var sourceRaw: String
    var note: String?
    var checkedAt: Date?

    init(id: UUID, householdID: UUID, itemID: UUID, itemName: String, list: ListKind, urgency: ListUrgency,
         source: ListItemSource, note: String?, checkedAt: Date?) {
        self.id = id
        self.householdID = householdID
        self.itemID = itemID
        self.itemName = itemName
        listRaw = list.rawValue
        urgencyRaw = urgency.rawValue
        sourceRaw = source.rawValue
        self.note = note
        self.checkedAt = checkedAt
    }

    var list: ListKind { ListKind(rawValue: listRaw) ?? .quick }
    var urgency: ListUrgency {
        get { ListUrgency(rawValue: urgencyRaw) ?? .whenever }
        set { urgencyRaw = newValue.rawValue }
    }
}

@Model
final class CachedItem {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var name: String
    var categoryRaw: String
    var keepOnHand: Bool
    var stockStateRaw: String?

    init(_ row: ItemRow) {
        id = row.id
        householdID = row.householdID
        name = row.canonicalName
        categoryRaw = row.category.rawValue
        keepOnHand = row.keepOnHand
        stockStateRaw = row.stockState?.rawValue
    }

    var stockState: StockState? {
        get { stockStateRaw.flatMap(StockState.init(rawValue:)) }
        set { stockStateRaw = newValue?.rawValue }
    }
}

/// A queued offline change. `sequence` preserves the order changes were made in, across relaunches.
@Model
final class PendingChange {
    var sequence: Int
    var householdID: UUID
    var payload: Data
    var attempts: Int
    var createdAt: Date

    init(sequence: Int, householdID: UUID, change: OfflineChange) throws {
        self.sequence = sequence
        self.householdID = householdID
        payload = try JSONEncoder().encode(change)
        attempts = 0
        createdAt = .now
    }

    var change: OfflineChange? { try? JSONDecoder().decode(OfflineChange.self, from: payload) }
}
