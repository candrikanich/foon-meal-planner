import Foundation

/// The 9 major US allergens plus Other. Raw values mirror the Postgres enum `public.allergen`.
/// Declaration order is the order flags and chips appear in.
enum Allergen: String, Codable, Sendable, CaseIterable, Comparable {
    case milk
    case eggs
    case fish
    case shellfish
    case treeNuts = "tree_nuts"
    case peanuts
    case wheat
    case soy
    case sesame
    /// Free text a guardian typed; the text lives on `MemberAllergies.customTexts`.
    case custom

    /// Lowercase, so it reads inside a sentence: "Contains tree nuts (Nora)".
    var displayName: String {
        switch self {
        case .treeNuts: "tree nuts"
        case .custom: "other"
        default: rawValue
        }
    }

    static func < (lhs: Allergen, rhs: Allergen) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
