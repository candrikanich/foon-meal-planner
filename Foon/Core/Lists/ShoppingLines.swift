import Foundation

/// One thing to buy for a planned meal.
struct ShoppingLine: Equatable, Sendable {
    let itemID: UUID
    let name: String
    let quantity: String?
    /// The meal (or side) it's for, so the list can say why it's there.
    let forMeal: String
}

/// What a planned meal puts on the weekly list: its ingredients, then its sides. A side meal adds its
/// ingredients; a simple side adds itself. One level only, so sides of sides never pile on. A side meal
/// retired since it was linked is skipped. Lines aren't merged here: the same item from a meal and its side
/// shows twice, and the list merges by item when it's added (add_to_list). Allergy flags read these lines
/// too, so what's flagged is what's served.
enum ShoppingLines {
    static func lines(for meal: LibraryMeal, library: [LibraryMeal]) -> [ShoppingLine] {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ingredients(of: meal) + meal.sides.flatMap { side -> [ShoppingLine] in
            switch side {
            case .meal(let id):
                guard let side = byID[id], side.status != .retired else { return [] }
                return ingredients(of: side)
            case .item(let itemID, let name):
                return [ShoppingLine(itemID: itemID, name: name, quantity: nil, forMeal: meal.name)]
            }
        }
    }

    private static func ingredients(of meal: LibraryMeal) -> [ShoppingLine] {
        meal.ingredients.map {
            ShoppingLine(itemID: $0.itemID, name: $0.name, quantity: $0.quantityText, forMeal: meal.name)
        }
    }
}
