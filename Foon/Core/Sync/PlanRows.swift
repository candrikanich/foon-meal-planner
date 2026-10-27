import Foundation

// Server rows for the week and the lists, as PostgREST returns them. Raw values match the Postgres enums.

enum ListKind: String, Codable, Sendable { case weekly, quick }
enum ListUrgency: String, Codable, Sendable { case tonight, whenever }
enum ListItemSource: String, Codable, Sendable { case plan, pivot, staple, manual, shared }
enum StockState: String, Codable, Sendable { case `in`, low, out }
enum NightEffort: String, Codable, Sendable { case normal, rushed, full, event }
enum QuickPick: String, Codable, Sendable {
    case leftovers, takeout
    case eatOut = "eat_out"
    case fendForYourselves = "fend_for_yourselves"
    case freezerRaid = "freezer_raid"
}
/// Mirrors Postgres `item_category`. Household and personal care are the non-food categories.
enum ItemCategory: String, Codable, CaseIterable, Sendable {
    case produce, bakery, pantry, frozen, snacks, beverages, household, other
    case meatSeafood = "meat_seafood"
    case dairyEggs = "dairy_eggs"
    case personalCare = "personal_care"

    /// A category this app version doesn't know yet reads as Other, so a new one never breaks sync.
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

struct PlanRow: Decodable, Equatable, Sendable {
    let id: UUID
    let householdID: UUID
    let weekStart: CalendarDay
    let approvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case weekStart = "week_start"
        case approvedAt = "approved_at"
    }
}

struct NightRow: Decodable, Equatable, Sendable {
    let id: UUID
    let planID: UUID
    let date: CalendarDay
    let effort: NightEffort
    let dinnerTime: String?
    let mealID: UUID?
    let mealName: String?
    let quickPick: QuickPick?
    let locked: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, effort, locked
        case planID = "plan_id"
        case dinnerTime = "dinner_time"
        case mealID = "meal_id"
        case quickPick = "quick_pick"
        case meal = "meals"
    }

    private struct EmbeddedMeal: Decodable { let name: String }

    init(id: UUID, planID: UUID, date: CalendarDay, effort: NightEffort, dinnerTime: String?, mealID: UUID?,
         mealName: String?, quickPick: QuickPick?, locked: Bool) {
        (self.id, self.planID, self.date, self.effort, self.dinnerTime) = (id, planID, date, effort, dinnerTime)
        (self.mealID, self.mealName, self.quickPick, self.locked) = (mealID, mealName, quickPick, locked)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        planID = try container.decode(UUID.self, forKey: .planID)
        date = try container.decode(CalendarDay.self, forKey: .date)
        effort = try container.decode(NightEffort.self, forKey: .effort)
        dinnerTime = try container.decodeIfPresent(String.self, forKey: .dinnerTime)
        mealID = try container.decodeIfPresent(UUID.self, forKey: .mealID)
        mealName = try container.decodeIfPresent(EmbeddedMeal.self, forKey: .meal)?.name
        quickPick = try container.decodeIfPresent(QuickPick.self, forKey: .quickPick)
        locked = try container.decode(Bool.self, forKey: .locked)
    }
}

struct ListItemRow: Decodable, Equatable, Sendable {
    let id: UUID
    let householdID: UUID
    let itemID: UUID
    let list: ListKind
    let urgency: ListUrgency
    let source: ListItemSource
    let note: String?
    let checkedAt: Date?
    /// The amounts the week's plan calls for ("1 lb + 1 lb").
    var quantity: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, list, urgency, source, note, quantity
        case householdID = "household_id"
        case itemID = "item_id"
        case checkedAt = "checked_at"
    }
}

struct ItemRow: Decodable, Equatable, Sendable {
    let id: UUID
    let householdID: UUID
    let canonicalName: String
    let category: ItemCategory
    let keepOnHand: Bool
    let stockState: StockState?
    /// The family's standing preference ("Vanilla, not plain").
    var note: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, category, note
        case householdID = "household_id"
        case canonicalName = "canonical_name"
        case keepOnHand = "keep_on_hand"
        case stockState = "stock_state"
    }
}

/// Everything the device keeps for offline use: the current week, the open lists, and the household's items.
struct SyncSnapshot: Equatable, Sendable {
    var plan: PlanRow?
    var nights: [NightRow]
    var listItems: [ListItemRow]
    var items: [ItemRow]
}
