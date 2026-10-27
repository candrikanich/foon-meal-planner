/// What each allergen looks like in a plain ingredient name. Phrases match whole words, ignoring
/// case, accents, and plurals, so "egg" never matches "eggplant" and "nut" never matches "nutmeg".
///
/// A missed allergen is far worse than an extra flag, so the list leans toward flagging:
/// - A dish that names a classic recipe (pesto, caesar, quiche) is flagged for what that recipe is made of,
///   because a family can't see inside the jar.
/// - One-word compounds are caught by vetted word starts and ends (cheese*, *bread, *cake, *fish), with
///   lookalikes listed for the false hits (breadfruit, shellfish).
/// - Packaged foods that usually carry an allergen are flagged for it (meatballs, pierogies, garlic bread).
///   Seasonings and sauces whose recipe varies a lot by brand (onion soup mix, enchilada sauce, taco
///   seasoning) are left alone rather than guessed at.
struct AllergenKeywords: Sendable {
    let allergen: Allergen
    /// Phrases that mean the ingredient contains the allergen.
    let phrases: [String]
    /// A single word that starts with one of these counts ("cheesecake", "crabmeat").
    let wordStarts: [String]
    /// A single word that ends with one of these counts ("flatbread", "monkfish").
    let wordEnds: [String]
    /// Phrases or words that look like a match but aren't ("coconut milk", "breadfruit").
    /// A keyword inside one is ignored.
    let lookalikes: [String]
    /// Labels that rule the allergen out for the whole ingredient ("gluten-free pasta").
    /// Any of the allergen's own phrases followed by "free" ("soy-free") does too, except "free-range".
    let freeFrom: [String]

    init(allergen: Allergen, phrases: [String], wordStarts: [String] = [], wordEnds: [String] = [],
         lookalikes: [String] = [], freeFrom: [String] = []) {
        self.allergen = allergen
        self.phrases = phrases
        self.wordStarts = wordStarts
        self.wordEnds = wordEnds
        self.lookalikes = lookalikes
        self.freeFrom = freeFrom
    }

    static let all: [AllergenKeywords] = [milk, eggs, fish, shellfish, treeNuts, peanuts, wheat, soy, sesame]

    /// Category words guardians type under Other instead of tapping the chip. Any of these inside a custom
    /// text ("no dairy", "tree nut allergy") also flags the allergens they stand for.
    static let categoryWords: [(phrase: String, allergens: Set<Allergen>)] = [
        ("gluten", [.wheat]), ("wheat", [.wheat]),
        ("dairy", [.milk]), ("lactose", [.milk]), ("milk", [.milk]),
        ("egg", [.eggs]),
        ("fish", [.fish]), ("seafood", [.fish, .shellfish]), ("shellfish", [.shellfish]),
        ("nut", [.treeNuts, .peanuts]), ("peanut", [.peanuts]),
        ("soy", [.soy]), ("sesame", [.sesame]),
    ]

    private static let veganFree = ["vegan", "plant based"]

    /// "Non-dairy" is not a free-from label: US rules let non-dairy creamers and toppings contain caseinate.
    static let milk = AllergenKeywords(
        allergen: .milk,
        phrases: [
            "milk", "buttermilk", "butter", "ghee", "cream", "creamer", "creme", "creme fraiche", "half and half",
            "whipped topping", "yogurt", "yoghurt", "kefir", "whey", "casein", "caseinate", "pudding", "custard",
            "cheese", "cheesy", "fromage", "cheddar", "mozzarella", "parmesan", "parmigiano", "parm", "pecorino",
            "romano", "asiago", "gruyere", "mascarpone", "paneer", "cotija", "ricotta", "provolone", "feta",
            "gouda", "brie", "colby", "monterey jack", "pepper jack", "queso",
            // Recipes made with cheese, butter, cream, or milk.
            "alfredo", "bechamel", "tzatziki", "hollandaise", "lemon curd", "carbonara", "quiche", "crepe",
            "pesto", "caesar", "ranch", "croissant", "brioche", "pizza", "cornbread", "goldfish", "garlic bread",
            // Store-bought versions almost always have cheese, milk, or butter.
            "meatball", "pierogi", "pierogy",
        ],
        wordStarts: ["cheese", "butter"],
        wordEnds: ["milk"],
        lookalikes: [
            "coconut milk", "oat milk", "almond milk", "soy milk", "rice milk", "cashew milk", "hemp milk",
            "oatmilk", "coconutmilk", "almondmilk", "soymilk", "ricemilk", "cashewmilk",
            "coconut cream", "cream of coconut", "cream of tartar", "cream soda",
            "creme de menthe", "creme de cacao", "creme de cassis",
            "peanut butter", "almond butter", "cashew butter", "nut butter", "seed butter", "sunflower butter",
            "apple butter", "cocoa butter", "shea butter", "butter bean", "butter lettuce",
            "butternut", "butterfly", "buttercup", "butterhead", "butterbean", "cheesecloth",
            "romano bean", "pizza dough", "pizza crust", "pizza sauce",
        ],
        freeFrom: ["dairy free"] + veganFree
    )

    static let eggs = AllergenKeywords(
        allergen: .eggs,
        phrases: [
            "egg", "yolk", "mayonnaise", "mayo", "aioli", "meringue", "eggnog", "custard", "brulee",
            // Made with eggs or egg yolk.
            "hollandaise", "lemon curd", "carbonara", "quiche", "frittata", "crepe", "brioche", "cheesecake",
            "cornbread", "tartar sauce", "caesar", "ranch", "meatball", "pierogi", "pierogy",
        ],
        wordStarts: ["egg"],
        lookalikes: ["eggplant"],
        freeFrom: ["eggless"] + veganFree
    )

    static let fish = AllergenKeywords(
        allergen: .fish,
        phrases: [
            "fish", "salmon", "lox", "tilapia", "cod", "tuna", "anchovy", "sardine", "mackerel", "herring",
            "halibut", "trout", "haddock", "pollock", "mahi", "snapper", "flounder", "bass", "caviar", "roe",
            // Surimi is fish (and often crab too).
            "imitation crab",
            // Both are made with anchovies.
            "worcestershire", "caesar",
        ],
        wordEnds: ["fish"],
        lookalikes: ["shellfish", "crawfish", "crayfish", "goldfish", "jellyfish", "starfish", "swedish fish"],
        freeFrom: veganFree
    )

    /// Mollusks (clams, scallops, squid) are included: a family who picks "shellfish" means them too,
    /// even though the US label law only counts crustaceans.
    static let shellfish = AllergenKeywords(
        allergen: .shellfish,
        phrases: [
            "shellfish", "shrimp", "prawn", "scampi", "crab", "lobster", "crawfish", "crayfish", "langoustine",
            "langostino", "krill", "scallop", "clam", "mussel", "oyster", "squid", "calamari", "octopus",
        ],
        wordStarts: ["crab"],
        lookalikes: ["crab apple", "crabapple", "oyster cracker", "oyster mushroom"],
        freeFrom: veganFree
    )

    /// Coconut is left out, matching the FDA's 2025 tree nut list.
    static let treeNuts = AllergenKeywords(
        allergen: .treeNuts,
        phrases: [
            "nut", "tree nut", "almond", "walnut", "pecan", "cashew", "pistachio", "hazelnut", "filbert",
            "macadamia", "chestnut", "praline", "marzipan", "nutella", "frangipane", "baklava",
            // Basil, parmesan, and pine nuts.
            "pesto",
        ],
        wordStarts: ["almond", "walnut", "pecan", "cashew", "pistachio", "hazelnut"],
        lookalikes: ["water chestnut"]
    )

    /// Plain "nuts" could be anything, peanuts included.
    static let peanuts = AllergenKeywords(
        allergen: .peanuts,
        phrases: ["peanut", "groundnut", "nut", "satay"],
        lookalikes: ["pine nut", "brazil nut", "macadamia nut", "cashew nut", "pistachio nut"],
        freeFrom: ["nut free"]
    )

    static let wheat = AllergenKeywords(
        allergen: .wheat,
        phrases: [
            "wheat", "flour", "bread", "breadcrumb", "panko", "crouton", "bun", "roll", "tortilla", "pita", "naan",
            "bagel", "muffin", "croissant", "brioche", "ciabatta", "baguette", "biscuit", "cracker", "pretzel",
            "matzo", "matzah", "matza", "pastry", "phyllo", "filo", "pie", "crepe", "quiche", "baklava",
            "pasta", "spaghetti", "macaroni", "mac", "ziti", "penne", "fettuccine", "linguine", "lasagna",
            "lasagne", "rigatoni", "rotini", "farfalle", "fusilli", "orzo", "tortellini", "ravioli", "gnocchi",
            "noodle", "udon", "ramen", "couscous", "semolina", "farina", "farro", "bulgur", "seitan", "spelt",
            "durum", "dough", "donut", "crust", "pizza", "pancake", "waffle", "pierogi", "pierogy", "dumpling",
            "potsticker", "wonton", "cake", "cookie", "brownie", "cheeseburger", "cheesesteak", "goldfish", "meatball",
            // Breaded.
            "nugget", "fish stick", "breaded",
            // Brewed with wheat.
            "soy sauce", "shoyu", "teriyaki", "hoisin", "ponzu", "stir fry sauce",
        ],
        wordStarts: ["bread", "dough"],
        wordEnds: ["bread", "cake", "dough"],
        lookalikes: [
            "corn tortilla", "tortilla chip", "rice noodle", "glass noodle", "cellophane noodle", "zucchini noodle",
            "shirataki noodle", "kelp noodle", "rice flour", "almond flour", "coconut flour", "corn flour",
            "oat flour", "chickpea flour", "cassava flour", "tapioca flour", "potato flour",
            "pasta sauce", "spaghetti sauce", "pizza sauce", "rice cake", "ricecake", "rice cracker",
            "pancake syrup", "waffle fry", "fruit roll", "breadfruit",
        ],
        freeFrom: ["gluten free", "grain free"]
    )

    static let soy = AllergenKeywords(
        allergen: .soy,
        phrases: [
            "soy", "soya", "soybean", "tofu", "edamame", "tempeh", "miso", "natto", "tamari", "shoyu",
            // Soy sauce bases.
            "teriyaki", "hoisin", "ponzu", "stir fry sauce",
        ],
        wordStarts: ["soy"]
    )

    static let sesame = AllergenKeywords(
        allergen: .sesame,
        phrases: ["sesame", "tahini", "hummus", "benne", "halva", "halvah"]
    )
}
