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
        case .milk: String(localized: "milk", comment: "Allergen, lowercase inside a sentence")
        case .eggs: String(localized: "eggs", comment: "Allergen, lowercase inside a sentence")
        case .fish: String(localized: "fish", comment: "Allergen, lowercase inside a sentence")
        case .shellfish: String(localized: "shellfish", comment: "Allergen, lowercase inside a sentence")
        case .treeNuts: String(localized: "tree nuts", comment: "Allergen, lowercase inside a sentence")
        case .peanuts: String(localized: "peanuts", comment: "Allergen, lowercase inside a sentence")
        case .wheat: String(localized: "wheat", comment: "Allergen, lowercase inside a sentence")
        case .soy: String(localized: "soy", comment: "Allergen, lowercase inside a sentence")
        case .sesame: String(localized: "sesame", comment: "Allergen, lowercase inside a sentence")
        case .custom: String(localized: "other", comment: "Allergen, lowercase inside a sentence")
        }
    }

    static func < (lhs: Allergen, rhs: Allergen) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
