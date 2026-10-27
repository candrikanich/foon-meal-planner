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
    let name: String
    let quantityText: String?
    let position: Int
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
