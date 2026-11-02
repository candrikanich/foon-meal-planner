import Foundation

/// Mirrors Postgres `meal_tag`.
enum MealTag: String, Codable, CaseIterable, Sendable {
    case quick
    case grill
    case slowCooker = "slow_cooker"
    case thawFirst = "thaw_first"
    case leftovers
    case backup
    case beginner

    var title: String {
        switch self {
        case .quick: String(localized: "Quick")
        case .grill: String(localized: "Needs grill")
        case .slowCooker: String(localized: "Slow cooker")
        case .thawFirst: String(localized: "Thaw first")
        case .leftovers: String(localized: "Makes leftovers")
        case .backup: String(localized: "Backup dinner")
        case .beginner: String(localized: "Beginner-friendly")
        }
    }
}

/// Mirrors Postgres `meal_status`. Archived meals are recoverable; retired ones were dropped by dislike rules.
enum MealStatus: String, Codable, Sendable {
    case active
    case trial
    case archived
    case retired

    var isInRotation: Bool { self == .active || self == .trial }
}

struct MealIngredient: Codable, Equatable, Sendable {
    /// The household item the line points at, for Add to list.
    let itemID: UUID
    let name: String
    let quantityText: String?
    let position: Int
    /// The item's standing note or brand preference.
    var note: String? = nil
    var category: ItemCategory = .other
    var keepOnHand = false

    var details: ItemDetails {
        ItemDetails(id: itemID, name: name, category: category, note: note, keepOnHand: keepOnHand)
    }
}

/// A meal in the household's library, with its ingredient lines.
struct LibraryMeal: Identifiable, Equatable, Sendable {
    let id: UUID
    let householdID: UUID
    var catalogMealID: UUID?
    var name: String
    var servings: Int
    var tags: [MealTag]
    var status: MealStatus
    var photoPath: String?
    var madeByMemberID: UUID?
    let createdAt: Date
    /// In recipe order.
    var ingredients: [MealIngredient]
    /// Optional recipe steps, in order.
    var steps: [String]
    var sourceURL: URL?
    /// Things to start ahead of dinner (thaw, marinate, slow cooker).
    var prepSteps: [PrepStep]
    /// What it's served with, in order.
    var sides: [MealSide] = []
    /// How long it takes, in minutes before dinner. Without one, the start-cooking nudge estimates from the tags.
    var cookMinutes: Int? = nil
}

/// A side dish: another meal from the library (Caesar salad) or a simple item (garlic bread).
enum MealSide: Equatable, Hashable, Sendable {
    case meal(UUID)
    case item(itemID: UUID, name: String)
}

/// One `meals.prep_steps` entry: `{"step": "Thaw the beef", "lead_hours": 24}`.
struct PrepStep: Codable, Equatable, Sendable {
    let step: String
    let leadHours: Int?

    private enum CodingKeys: String, CodingKey {
        case step
        case leadHours = "lead_hours"
    }
}

/// Prep steps as they come off the server. One that won't read shouldn't cost the others, or everything else being loaded.
struct LenientPrepSteps: Decodable, Sendable {
    private struct Entry: Decodable {
        let step: PrepStep?

        init(from decoder: Decoder) throws {
            step = try? PrepStep(from: decoder)
        }
    }

    let steps: [PrepStep]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        steps = ((try? container.decode([Entry].self)) ?? []).compactMap(\.step)
    }
}

/// Times made and last made, from the `meal_history` view.
struct MealHistory: Decodable, Equatable, Sendable {
    let mealID: UUID
    let timesMade: Int
    let lastMade: CalendarDay

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case timesMade = "times_made"
        case lastMade = "last_made"
    }
}

/// A starter dish from the shared catalog (docs/starter-pack.md).
struct CatalogDish: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let category: String
    let tags: [MealTag]
    let popular: Bool
    let sortOrder: Int
    /// Ingredient names in recipe order.
    let ingredients: [String]
}
