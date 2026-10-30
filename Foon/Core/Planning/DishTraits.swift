import Foundation

/// The seasons Build my week leans toward a kind of dish. Spring and fall lean nowhere.
enum Season: Sendable {
    case summer
    case winter
}

extension CalendarDay {
    /// Meteorological seasons, northern hemisphere (US launch): June to August, December to February.
    var season: Season? {
        switch month {
        case 6...8: .summer
        case 12, 1, 2: .winter
        default: nil
        }
    }
}

/// A kind of dinner a family might notice repeating, roughly the starter pack's categories. A dish can be several
/// ("Chicken Alfredo" is pasta and chicken). Food types only: never calories or nutrition (docs/spec.md).
enum DishCategory: CaseIterable, Hashable, Sendable {
    case pasta, texMex, sandwiches, soup, pizza, grilling, chicken, beef, pork, seafood, breakfast

    var title: String {
        switch self {
        case .pasta: String(localized: "Pasta", comment: "Dish category in a variety note: Pasta 3 times this week")
        case .texMex: String(localized: "Tex-Mex", comment: "Dish category in a variety note")
        case .sandwiches: String(localized: "Sandwiches", comment: "Dish category in a variety note")
        case .soup: String(localized: "Soup", comment: "Dish category in a variety note")
        case .pizza: String(localized: "Pizza", comment: "Dish category in a variety note")
        case .grilling: String(localized: "Grilling", comment: "Dish category in a variety note")
        case .chicken: String(localized: "Chicken", comment: "Dish category in a variety note")
        case .beef: String(localized: "Beef", comment: "Dish category in a variety note")
        case .pork: String(localized: "Pork", comment: "Dish category in a variety note")
        case .seafood: String(localized: "Seafood", comment: "Dish category in a variety note")
        case .breakfast: String(localized: "Breakfast for dinner", comment: "Dish category in a variety note")
        }
    }
}

/// What a dish's name says about it. Meals carry no category or soup tag, so this reads the name, which also covers
/// dishes the family typed in or renamed. Whole words, in English; a name it can't read just gets no lean either way.
struct DishTraits: Equatable, Sendable {
    let categories: Set<DishCategory>
    /// Served cold or close to it: Build my week's summer lean, alongside grill-tagged dishes.
    let isCold: Bool

    init(name: String) {
        let words = Words(name)
        let cold = Self.cold.isFound(in: words)
        var categories = Set(Self.keywords.filter { $0.value.isFound(in: words) }.keys)
        // A cold soup is a summer dish, not the bowl winter leans toward.
        if cold { categories.remove(.soup) }
        self.categories = categories
        isCold = cold
    }

    /// A dish fits a season once, however many ways it qualifies.
    func isInSeason(_ season: Season?, tags: [MealTag]) -> Bool {
        switch season {
        case .summer: isCold || tags.contains(.grill)
        case .winter: categories.contains(.soup) || tags.contains(.slowCooker)
        case nil: false
        }
    }

    private struct Keywords: Sendable {
        let phrases: [[Word]]
        /// Names that look like a match but aren't: a "chili dog" isn't a bowl of chili.
        let lookalikes: [[Word]]

        init(_ phrases: [String], except lookalikes: [String] = []) {
            self.phrases = phrases.map { Words($0).tokens }
            self.lookalikes = lookalikes.map { Words($0).tokens }
        }

        func isFound(in words: Words) -> Bool {
            phrases.contains(where: words.contains) && !lookalikes.contains(where: words.contains)
        }
    }

    private static let cold = Keywords(["salad", "gazpacho", "cold", "chilled", "ceviche", "poke", "hoagie",
                                        "italian sub", "wrap", "blt"])

    private static let keywords: [DishCategory: Keywords] = [
        .pasta: Keywords(["pasta", "spaghetti", "penne", "rigatoni", "linguine", "fettuccine", "noodle", "macaroni",
                          "mac and cheese", "ziti", "lasagna", "lasagne", "alfredo", "carbonara", "ravioli",
                          "tortellini", "gnocchi", "lo mein"], except: ["noodle soup"]),
        .texMex: Keywords(["taco", "burrito", "quesadilla", "enchilada", "nacho", "fajita", "tostada", "tamale",
                           "salsa"]),
        .sandwiches: Keywords(["sandwich", "sub", "hoagie", "panini", "blt", "wrap", "sloppy joe", "french dip",
                               "grilled cheese"]),
        .soup: Keywords(["soup", "stew", "chowder", "bisque", "gumbo", "chili", "minestrone"],
                        except: ["chili dog", "chili cheese", "chili lime", "chili garlic", "sweet chili"]),
        .pizza: Keywords(["pizza", "calzone"]),
        .grilling: Keywords(["grilled", "burger", "hamburger", "cheeseburger", "hot dog", "chili dog", "brat",
                             "bratwurst", "kebab", "kabob", "steak"], except: ["grilled cheese"]),
        .chicken: Keywords(["chicken"]),
        .beef: Keywords(["beef", "steak", "burger", "hamburger", "cheeseburger", "meatloaf", "meatball", "pot roast",
                         "brisket", "sloppy joe", "shepherds pie", "cottage pie", "french dip"]),
        .pork: Keywords(["pork", "ham", "sausage", "brat", "bratwurst"]),
        .seafood: Keywords(["fish", "salmon", "tilapia", "tuna", "cod", "shrimp", "crab", "scallop", "lobster"]),
        .breakfast: Keywords(["breakfast", "pancake", "waffle", "french toast", "omelet", "omelette", "frittata"]),
    ]
}

/// A quiet note on the week: "Pasta 3 times this week" (docs/spec.md → Variety nudges). It only tells; the planner
/// decides. The draw has already leaned away, so a nudge means the family's picks or library kept landing there.
struct VarietyNudge: Equatable, Sendable {
    /// The issue's own example: twice in a week is ordinary, three times is worth a mention.
    static let threshold = 3

    let category: DishCategory
    let count: Int

    func text(nextWeek: Bool) -> String {
        nextWeek
            ? String(localized: "\(category.title) \(count) times next week",
                     comment: "Variety note on the week: Pasta 3 times next week")
            : String(localized: "\(category.title) \(count) times this week",
                     comment: "Variety note on the week: Pasta 3 times this week")
    }

    /// Most repeated first; ties in `DishCategory` order, so the notes never reorder between loads.
    static func nudges(mealNames: [String]) -> [VarietyNudge] {
        let categories = mealNames.flatMap { DishTraits(name: $0).categories }
        return DishCategory.allCases
            .map { category in VarietyNudge(category: category, count: categories.filter { $0 == category }.count) }
            .filter { $0.count >= threshold }
            .enumerated()
            .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
            .map(\.element)
    }
}
