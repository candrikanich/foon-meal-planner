import Foundation

/// Equipment a dish can need that plenty of kitchens don't have. A household lists what it's missing
/// (`HouseholdSettings.missingEquipment`), so anything it hasn't said anything about counts as there.
enum KitchenEquipment: String, Codable, CaseIterable, Sendable {
    case grill
    case slowCooker = "slow_cooker"
    case airFryer = "air_fryer"
    case instantPot = "instant_pot"

    var title: String {
        switch self {
        case .grill: String(localized: "Grill", comment: "Kitchen equipment")
        case .slowCooker: String(localized: "Slow cooker", comment: "Kitchen equipment")
        case .airFryer: String(localized: "Air fryer", comment: "Kitchen equipment")
        case .instantPot: String(localized: "Instant Pot", comment: "Kitchen equipment")
        }
    }

    /// On a card or swap suggestion, for a dish the household doesn't have this for.
    var needsText: String {
        switch self {
        case .grill: String(localized: "Needs a grill", comment: "Day card badge: the household has no grill")
        case .slowCooker: String(localized: "Needs a slow cooker", comment: "Day card badge: the household has none")
        case .airFryer: String(localized: "Needs an air fryer", comment: "Day card badge: the household has none")
        case .instantPot: String(localized: "Needs an Instant Pot", comment: "Day card badge: the household has none")
        }
    }
}

extension HouseholdSettings {
    /// What this dish needs that the household doesn't have, in the list's order.
    func missingEquipment(for meal: LibraryMeal) -> [KitchenEquipment] {
        guard !missingEquipment.isEmpty else { return [] }
        let needs = DishTraits(name: meal.name, tags: meal.tags).equipment
        return KitchenEquipment.allCases.filter { needs.contains($0) && missingEquipment.contains($0) }
    }

    /// Whether suggestions are leaving out any dish the family could otherwise be offered.
    func setsAsideDishes(in meals: [LibraryMeal]) -> Bool {
        meals.contains { $0.status.isInRotation && !missingEquipment(for: $0).isEmpty }
    }
}
