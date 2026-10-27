import Foundation

extension ItemCategory {
    var title: String {
        switch self {
        case .produce: String(localized: "Produce")
        case .meatSeafood: String(localized: "Meat and seafood")
        case .dairyEggs: String(localized: "Dairy and eggs")
        case .bakery: String(localized: "Bakery")
        case .pantry: String(localized: "Pantry")
        case .frozen: String(localized: "Frozen")
        case .snacks: String(localized: "Snacks")
        case .beverages: String(localized: "Drinks")
        case .household: String(localized: "Household")
        case .personalCare: String(localized: "Personal care")
        case .other: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .produce: "carrot"
        case .meatSeafood: "fish"
        case .dairyEggs: "oval.portrait"
        case .bakery: "birthday.cake"
        case .pantry: "cabinet"
        case .frozen: "snowflake"
        case .snacks: "popcorn"
        case .beverages: "cup.and.saucer"
        case .household: "house"
        case .personalCare: "heart.text.square"
        case .other: "basket"
        }
    }

    /// Household and personal care share the list with groceries but aren't food.
    var isFood: Bool { self != .household && self != .personalCare }

    /// The order store mode walks the aisles: fresh first, frozen near the end, then non-food, then the rest.
    static let storeOrder: [ItemCategory] = [
        .produce, .bakery, .meatSeafood, .dairyEggs, .pantry, .snacks, .beverages, .frozen,
        .household, .personalCare, .other
    ]

    /// A non-food category for an item the starter pack doesn't know, from whole-word phrases
    /// ("paper towels", not "paper-thin ham"). Nil means groceries: the catalog's guess or Other applies.
    static func guess(for name: String) -> ItemCategory? {
        // Checked in this order: foods that borrow a non-food word, then household before personal care,
        // so "disinfecting wipes" is cleaning and only "wipes" alone is personal care.
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func has(_ phrase: String) -> Bool {
            let target = phrase.split(separator: " ").map(String.init)
            guard target.count <= words.count else { return false }
            return (0...(words.count - target.count)).contains { Array(words[$0..<$0 + target.count]) == target }
        }
        if foodPhrases.contains(where: has) { return nil }
        if householdPhrases.contains(where: has) { return .household }
        if personalCarePhrases.contains(where: has) { return .personalCare }
        return nil
    }

    private static let foodPhrases = ["sponge cake", "sponge fingers", "candy floss", "cotton candy"]

    private static let householdPhrases = [
        "paper towels", "paper towel", "toilet paper", "tissues", "napkins", "paper plates", "trash bags",
        "garbage bags", "dish soap", "dishwasher", "detergent", "laundry", "fabric softener", "dryer sheets",
        "bleach", "cleaner", "sponges", "sponge", "aluminum foil", "tin foil", "plastic wrap", "ziploc",
        "sandwich bags", "freezer bags", "parchment paper", "batteries", "light bulbs", "lightbulbs",
        "disinfecting wipes", "cleaning wipes", "clorox wipes", "scouring pads", "brillo"
    ]

    private static let personalCarePhrases = [
        "toothpaste", "toothbrush", "toothbrushes", "floss", "mouthwash", "shampoo", "conditioner", "body wash",
        "hand soap", "bar soap", "deodorant", "lotion", "sunscreen", "razors", "shaving cream", "diapers", "wipes",
        "tampons", "pads", "band aids", "bandaids", "cotton swabs", "q tips", "vitamins", "ibuprofen"
    ]
}
