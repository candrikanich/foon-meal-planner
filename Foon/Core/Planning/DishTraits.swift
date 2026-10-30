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

    /// The name in a variety note. Proteins have none and never make a note: a name can't tell a turkey burger from
    /// a beef one, so "Beef 3 times this week" could be false. A wrong guess is harmless in the draw, not in a sentence.
    var title: String? {
        switch self {
        case .pasta: String(localized: "Pasta", comment: "Dish category in a variety note: Pasta 3 times this week")
        case .texMex: String(localized: "Tex-Mex", comment: "Dish category in a variety note")
        case .sandwiches: String(localized: "Sandwiches", comment: "Dish category in a variety note")
        case .soup: String(localized: "Soup", comment: "Dish category in a variety note")
        case .pizza: String(localized: "Pizza", comment: "Dish category in a variety note")
        case .grilling: String(localized: "Grilling", comment: "Dish category in a variety note")
        case .breakfast: String(localized: "Breakfast for dinner", comment: "Dish category in a variety note")
        case .chicken, .beef, .pork, .seafood: nil
        }
    }
}

/// What a dish's name says about it. Meals carry no category or soup tag, so this reads the name, which also covers
/// dishes the family typed in or renamed. Whole words, in English; a name it can't read just gets no lean either way.
struct DishTraits: Equatable, Sendable {
    let categories: Set<DishCategory>
    /// Served cold or close to it: Build my week's summer lean, alongside grill-tagged dishes.
    let isCold: Bool
    /// What it usually takes to make it: a tag, or a name that says so. Meals have no tag for an air fryer or an Instant Pot, and
    /// a new tag would break reading the library on apps already installed (`MealTag` decoding is strict).
    let equipment: Set<KitchenEquipment>
    private let tags: [MealTag]

    /// The planner passes the tags, so a grill-tagged "Carne asada" counts as a grilling repeat just as it gets the
    /// summer boost. The nudge has only the names saved with the week.
    init(name: String, tags: [MealTag] = []) {
        let words = Words(name)
        var categories = Set(Self.keywords.filter { $0.value.isFound(in: words) }.keys)
        if tags.contains(.grill) { categories.insert(.grilling) }
        // The name saying cold makes a soup a summer dish. A salad beside a hot soup doesn't, and it doesn't make the
        // whole dinner cold either.
        let saysCold = Self.saysCold.isFound(in: words)
        if saysCold { categories.remove(.soup) }
        isCold = saysCold || (Self.servedCool.isFound(in: words) && !categories.contains(.soup))
        self.categories = categories
        self.tags = tags
        var equipment = Set(Self.equipmentNames.filter { $0.value.isFound(in: words) }.keys)
        if tags.contains(.grill) { equipment.insert(.grill) }
        if tags.contains(.slowCooker) { equipment.insert(.slowCooker) }
        self.equipment = equipment
    }

    /// A dish fits a season once, however many ways it qualifies.
    func isInSeason(_ season: Season?) -> Bool {
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

        /// A lookalike rules out only the words it covers: "sweet chili chicken soup" is still soup.
        func isFound(in words: Words) -> Bool {
            let ruledOut = lookalikes.flatMap(words.occurrences)
            return phrases.flatMap(words.occurrences).contains { hit in !ruledOut.contains { $0.overlaps(hit) } }
        }
    }

    private static let saysCold = Keywords(["cold", "chilled", "gazpacho"],
                                           except: ["cold night", "cold day", "cold weather", "cold snap"])

    private static let servedCool = Keywords(["salad", "ceviche", "poke", "hoagie", "italian sub", "wrap", "blt"])

    private static let equipmentNames: [KitchenEquipment: Keywords] = [
        .grill: Keywords(["grilled", "on the grill", "from the grill", "mixed grill"],
                         except: ["grilled cheese", "grilled ham and cheese", "grilled pb and j", "grilled pbj",
                                  "pan grilled"]),
        .slowCooker: Keywords(["slow cooker", "slowcooker", "slow cook", "slow cooked", "crock pot", "crockpot"]),
        .airFryer: Keywords(["air fryer", "airfryer", "air fried", "airfried", "air fry"]),
        .instantPot: Keywords(["instant pot", "instantpot", "instapot", "pressure cooker"]),
    ]

    private static let keywords: [DishCategory: Keywords] = [
        .pasta: Keywords(["pasta", "spaghetti", "penne", "rigatoni", "linguine", "fettuccine", "noodle", "macaroni",
                          "mac and cheese", "ziti", "lasagna", "lasagne", "alfredo", "carbonara", "ravioli",
                          "tortellini", "gnocchi", "lo mein"],
                         except: ["noodle soup", "spaghetti squash", "zucchini noodle"]),
        .texMex: Keywords(["taco", "burrito", "quesadilla", "enchilada", "nacho", "fajita", "tostada", "tamale",
                           "salsa"]),
        .sandwiches: Keywords(["sandwich", "sub", "hoagie", "panini", "blt", "wrap", "sloppy joe", "french dip",
                               "grilled cheese"]),
        .soup: Keywords(["soup", "stew", "chowder", "bisque", "gumbo", "chili", "minestrone"],
                        except: ["chili dog", "chili cheese", "chili lime", "chili garlic", "sweet chili", "thai chili",
                                 "honey chili", "soup dumpling"]),
        .pizza: Keywords(["pizza", "calzone"]),
        .grilling: Keywords(["grilled", "burger", "hamburger", "cheeseburger", "hot dog", "chili dog", "brat",
                             "bratwurst", "kebab", "kabob", "steak"],
                            except: ["grilled cheese", "hamburger helper", "salisbury steak", "fried steak"]),
        .chicken: Keywords(["chicken"], except: ["chicken fried steak"]),
        .beef: Keywords(["beef", "steak", "burger", "hamburger", "cheeseburger", "meatloaf", "meatball", "pot roast",
                         "brisket", "sloppy joe", "shepherds pie", "cottage pie", "french dip"]),
        .pork: Keywords(["pork", "ham", "sausage", "brat", "bratwurst"]),
        .seafood: Keywords(["fish", "salmon", "tilapia", "tuna", "cod", "shrimp", "crab", "scallop", "lobster"]),
        .breakfast: Keywords(["breakfast", "pancake", "waffle", "french toast", "omelet", "omelette", "frittata",
                              "egg sandwich"]),
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
        let title = category.title ?? ""
        return nextWeek
            ? String(localized: "\(title) \(count) times next week",
                     comment: "Variety note on the week: Pasta 3 times next week")
            : String(localized: "\(title) \(count) times this week",
                     comment: "Variety note on the week: Pasta 3 times this week")
    }

    /// One line at most: the most repeated category, ties in `DishCategory` order so it never flips between loads.
    static func nudge(mealNames: [String]) -> VarietyNudge? {
        let categories = mealNames.flatMap { DishTraits(name: $0).categories }
        return DishCategory.allCases
            .filter { $0.title != nil }
            .map { category in VarietyNudge(category: category, count: categories.filter { $0 == category }.count) }
            .filter { $0.count >= threshold }
            .enumerated()
            .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
            .first?.element
    }
}

extension WeekLayout {
    /// The whole week counts, past nights too, but a note is only worth showing while it can still change something:
    /// a night ahead that isn't locked, an event, or inside the away dates.
    var varietyNudge: VarietyNudge? {
        guard plannable.contains(where: { !$0.locked && $0.effort != .event }) else { return nil }
        return VarietyNudge.nudge(mealNames: (past + ahead).compactMap(\.mealName))
    }
}
