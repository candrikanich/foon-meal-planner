/// What each allergen looks like in a plain ingredient name. Phrases match whole words, ignoring
/// case and plurals, so "egg" never matches "eggplant" and "nut" never matches "nutmeg".
///
/// The list leans toward flagging: a dish that names a classic recipe (pesto, caesar, ranch) is flagged
/// for what that recipe is made of, because a family can't see inside the jar. Packaged foods whose
/// recipe varies (meatballs, onion soup mix, enchilada sauce) are left alone rather than guessed at.
struct AllergenKeywords: Sendable {
    let allergen: Allergen
    /// Phrases that mean the ingredient contains the allergen.
    let phrases: [String]
    /// Phrases that look like a match but aren't ("coconut milk"). A keyword inside one is ignored.
    let lookalikes: [String]
    /// Labels that rule the allergen out for the whole ingredient ("gluten-free pasta").
    /// Any of the allergen's own phrases followed by "free" ("soy-free") does too.
    let freeFrom: [String]

    static let all: [AllergenKeywords] = [milk, eggs, fish, shellfish, treeNuts, peanuts, wheat, soy, sesame]

    private static let veganFree = ["vegan", "plant based"]

    static let milk = AllergenKeywords(
        allergen: .milk,
        phrases: [
            "milk", "buttermilk", "butter", "ghee", "cream", "creamer", "half and half", "yogurt", "yoghurt",
            "whey", "casein", "caseinate", "cheese", "cheddar", "mozzarella", "parmesan", "parmigiano", "pecorino",
            "ricotta", "provolone", "feta", "gouda", "brie", "queso", "alfredo", "custard",
            // Recipes made with cheese or butter.
            "pesto", "caesar", "ranch", "croissant", "brioche", "pizza",
        ],
        lookalikes: [
            "coconut milk", "oat milk", "almond milk", "soy milk", "rice milk", "cashew milk", "hemp milk",
            "coconut cream", "cream of coconut", "cream of tartar", "cream soda",
            "peanut butter", "almond butter", "cashew butter", "nut butter", "seed butter", "sunflower butter",
            "apple butter", "cocoa butter", "shea butter", "butter bean", "butter lettuce",
            "pizza dough", "pizza crust", "pizza sauce",
        ],
        freeFrom: ["dairy free", "non dairy", "nondairy"] + veganFree
    )

    static let eggs = AllergenKeywords(
        allergen: .eggs,
        phrases: [
            "egg", "mayonnaise", "mayo", "aioli", "meringue", "eggnog", "hollandaise", "custard", "brioche",
            // Mayonnaise-based, or made with egg yolk.
            "tartar sauce", "caesar", "ranch",
        ],
        lookalikes: [],
        freeFrom: ["eggless"] + veganFree
    )

    static let fish = AllergenKeywords(
        allergen: .fish,
        phrases: [
            "fish", "salmon", "tilapia", "cod", "tuna", "anchovy", "sardine", "halibut", "trout", "haddock",
            "pollock", "catfish", "mahi", "swordfish", "snapper", "flounder", "sea bass", "imitation crab",
            // Both are made with anchovies.
            "worcestershire", "caesar",
        ],
        lookalikes: ["swedish fish"],
        freeFrom: veganFree
    )

    /// Mollusks (clams, scallops, oysters) are included: a family who picks "shellfish" means them too,
    /// even though the US label law only counts crustaceans.
    static let shellfish = AllergenKeywords(
        allergen: .shellfish,
        phrases: [
            "shellfish", "shrimp", "prawn", "crab", "lobster", "crawfish", "crayfish", "langoustine", "krill",
            "scallop", "clam", "mussel", "oyster",
        ],
        lookalikes: ["imitation crab", "crab apple", "oyster cracker", "oyster mushroom"],
        freeFrom: veganFree
    )

    /// Coconut is left out, matching the FDA's 2025 tree nut list.
    static let treeNuts = AllergenKeywords(
        allergen: .treeNuts,
        phrases: [
            "nut", "tree nut", "almond", "walnut", "pecan", "cashew", "pistachio", "hazelnut", "filbert",
            "macadamia", "chestnut", "praline", "marzipan", "nutella", "frangipane",
            // Basil, parmesan, and pine nuts.
            "pesto",
        ],
        lookalikes: ["water chestnut"],
        freeFrom: []
    )

    static let peanuts = AllergenKeywords(
        allergen: .peanuts,
        phrases: ["peanut", "groundnut", "mixed nut", "satay"],
        lookalikes: [],
        freeFrom: ["nut free"]
    )

    static let wheat = AllergenKeywords(
        allergen: .wheat,
        phrases: [
            "wheat", "flour", "bread", "breadcrumb", "panko", "crouton", "bun", "roll", "tortilla", "pita", "naan",
            "bagel", "muffin", "croissant", "brioche", "ciabatta", "baguette", "biscuit", "cracker", "pretzel",
            "pasta", "spaghetti", "macaroni", "mac", "ziti", "penne", "fettuccine", "linguine", "lasagna",
            "rigatoni", "rotini", "orzo", "tortellini", "ravioli", "gnocchi", "noodle", "couscous", "semolina",
            "farina", "bulgur", "seitan", "spelt", "durum", "dough", "crust", "pizza", "pancake", "waffle",
            "pierogi", "pierogy", "dumpling", "potsticker", "wonton", "cake", "cookie", "brownie",
            // Breaded.
            "nugget", "fish stick", "breaded",
            // Brewed with wheat.
            "soy sauce", "teriyaki", "hoisin", "stir fry sauce",
        ],
        lookalikes: [
            "corn tortilla", "tortilla chip", "rice noodle", "glass noodle", "cellophane noodle", "zucchini noodle",
            "rice flour", "almond flour", "coconut flour", "corn flour", "oat flour", "chickpea flour",
            "cassava flour", "tapioca flour", "potato flour", "pasta sauce", "spaghetti sauce", "pizza sauce",
            "shirataki noodle", "kelp noodle", "rice cake", "rice cracker", "pancake syrup", "waffle fry", "fruit roll",
        ],
        freeFrom: ["gluten free", "grain free"]
    )

    static let soy = AllergenKeywords(
        allergen: .soy,
        phrases: [
            "soy", "soya", "soybean", "tofu", "edamame", "tempeh", "miso", "natto", "tamari", "shoyu",
            // Soy sauce bases.
            "teriyaki", "hoisin", "stir fry sauce",
        ],
        lookalikes: [],
        freeFrom: []
    )

    static let sesame = AllergenKeywords(
        allergen: .sesame,
        phrases: ["sesame", "tahini", "hummus", "benne", "halva", "halvah"],
        lookalikes: [],
        freeFrom: []
    )
}
