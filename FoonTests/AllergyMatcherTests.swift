import Foundation
import Testing
@testable import Foon

struct AllergenTests {
    @Test func rawValuesMirrorThePostgresEnum() {
        #expect(Allergen.allCases.map(\.rawValue) == [
            "milk", "eggs", "fish", "shellfish", "tree_nuts", "peanuts", "wheat", "soy", "sesame", "custom",
        ])
    }

    @Test func sortsInChipOrder() {
        #expect([Allergen.sesame, .milk, .treeNuts, .eggs].sorted() == [.milk, .eggs, .treeNuts, .sesame])
    }

    @Test func readsInsideASentence() {
        #expect(Allergen.treeNuts.displayName == "tree nuts")
        #expect(Allergen.milk.displayName == "milk")
    }
}

struct AllergyKeywordTests {
    static let typical: [(String, Set<Allergen>)] = [
        // Milk
        ("milk", [.milk]),
        ("whole milk", [.milk]),
        ("Butter", [.milk]),
        ("unsalted butter", [.milk]),
        ("buttermilk", [.milk]),
        ("shredded cheddar cheese", [.milk]),
        ("parmesan", [.milk]),
        ("ricotta cheese", [.milk]),
        ("sour cream", [.milk]),
        ("heavy cream", [.milk]),
        ("cream cheese", [.milk]),
        ("plain yogurt", [.milk]),
        ("ghee", [.milk]),
        ("whey protein", [.milk]),
        ("sodium caseinate", [.milk]),
        ("casein", [.milk]),
        ("half-and-half", [.milk]),
        ("alfredo sauce", [.milk]),
        ("lactose-free milk", [.milk]),
        // Eggs
        ("eggs", [.eggs]),
        ("1 egg", [.eggs]),
        ("egg whites", [.eggs]),
        ("mayonnaise", [.eggs]),
        ("mayo", [.eggs]),
        ("tartar sauce", [.eggs]),
        // Fish
        ("salmon fillets", [.fish]),
        ("tilapia fillets", [.fish]),
        ("cod fillets", [.fish]),
        ("canned tuna", [.fish]),
        ("anchovies", [.fish]),
        ("fish sauce", [.fish]),
        ("worcestershire sauce", [.fish]),
        // Shellfish
        ("shrimp", [.shellfish]),
        ("crab meat", [.shellfish]),
        ("sea scallops", [.shellfish]),
        ("lobster tails", [.shellfish]),
        ("oyster sauce", [.shellfish]),
        // Tree nuts
        ("sliced almonds", [.treeNuts]),
        ("walnuts", [.treeNuts]),
        ("pine nuts", [.treeNuts]),
        ("cashews", [.treeNuts]),
        ("pecans", [.treeNuts]),
        ("chestnuts", [.treeNuts]),
        // Peanuts
        ("peanuts", [.peanuts]),
        ("creamy peanut butter", [.peanuts]),
        ("peanut oil", [.peanuts]),
        // Wheat
        ("flour", [.wheat]),
        ("all-purpose flour", [.wheat]),
        ("flour tortillas", [.wheat]),
        ("breadcrumbs", [.wheat]),
        ("panko", [.wheat]),
        ("spaghetti", [.wheat]),
        ("elbow macaroni", [.wheat]),
        ("hamburger buns", [.wheat]),
        ("dinner rolls", [.wheat]),
        ("english muffins", [.wheat]),
        ("pizza dough", [.wheat]),
        ("pancake and waffle mix", [.wheat]),
        ("frozen chicken nuggets", [.wheat]),
        ("couscous", [.wheat]),
        // Soy
        ("tofu", [.soy]),
        ("edamame", [.soy]),
        ("miso paste", [.soy]),
        ("tamari", [.soy]),
        // Sesame
        ("sesame seeds", [.sesame]),
        ("toasted sesame oil", [.sesame]),
        ("tahini", [.sesame]),
        ("hummus", [.sesame]),
    ]

    @Test(arguments: typical)
    func findsTypicalNames(name: String, expected: Set<Allergen>) {
        #expect(AllergyMatcher.allergens(in: name) == expected)
    }

    @Test(arguments: [
        "eggplant",
        "butternut squash",
        "nutmeg",
        "water chestnuts",
        "cream of tartar",
        "cocoa butter",
        "coconut milk",
        "oat milk",
        "rice noodles",
        "corn tortillas",
        "gluten-free pasta",
        "peanut-free granola",
        "butter beans",
        "butter lettuce",
        "tortilla chips",
        "pasta sauce",
        "pizza sauce",
        "coconut",
        "shellfish-free stock",
        "dairy-free cheese",
        "egg-free mayo",
        "vegan butter",
        "taco shells",
        "rice flour",
    ])
    func ignoresLookalikes(name: String) {
        #expect(AllergyMatcher.allergens(in: name).isEmpty)
    }

    static let combined: [(String, Set<Allergen>)] = [
        ("almond milk", [.treeNuts]),
        ("soy milk", [.soy]),
        ("almond butter", [.treeNuts]),
        ("egg noodles", [.eggs, .wheat]),
        ("soy sauce", [.soy, .wheat]),
        ("teriyaki sauce", [.soy, .wheat]),
        ("stir-fry sauce", [.soy, .wheat]),
        ("hoisin sauce", [.soy, .wheat]),
        // Pesto is basil, parmesan, and pine nuts.
        ("pesto", [.milk, .treeNuts]),
        // Caesar dressing is egg yolk, anchovy, and parmesan.
        ("caesar dressing", [.eggs, .fish, .milk]),
        // Ranch is buttermilk and mayonnaise.
        ("ranch dressing", [.milk, .eggs]),
        ("frozen fish sticks", [.fish, .wheat]),
        ("box mac and cheese", [.milk, .wheat]),
        ("frozen pizza", [.milk, .wheat]),
        ("croissants", [.milk, .wheat]),
        ("mixed nuts", [.treeNuts, .peanuts]),
        ("gluten-free soy sauce", [.soy]),
    ]

    @Test(arguments: combined)
    func findsEveryAllergenInCombinedIngredients(name: String, expected: Set<Allergen>) {
        #expect(AllergyMatcher.allergens(in: name) == expected)
    }

    @Test(arguments: ["MILK", "Peanut Butter", "Jalapeño cheese", "shepherd's pie crust", "  Eggs  "])
    func ignoresCaseAccentsAndPunctuation(name: String) {
        #expect(!AllergyMatcher.allergens(in: name).isEmpty)
    }

    @Test func emptyNameHasNoAllergens() {
        #expect(AllergyMatcher.allergens(in: "").isEmpty)
        #expect(AllergyMatcher.allergens(in: "  -  ").isEmpty)
    }

    @Test func neverReportsCustomFromTheKeywordMap() {
        let everything = ["milk", "eggs", "cod", "shrimp", "walnuts", "peanuts", "flour", "tofu", "tahini"]
        #expect(!everything.flatMap { AllergyMatcher.allergens(in: $0) }.contains(.custom))
    }
}

struct AllergyFlagTests {
    let nora = MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk, .treeNuts])
    let owen = MemberAllergies(memberID: UUID(), firstName: "Owen", allergens: [.milk])
    let ada = MemberAllergies(memberID: UUID(), firstName: "Ada", customTexts: ["Strawberries"])

    @Test func flagsAMilkDishForTheMemberWhoCantHaveIt() {
        let flags = AllergyMatcher.flags(ingredients: ["elbow macaroni", "shredded cheddar cheese", "milk"],
                                         members: [nora])
        #expect(flags == [
            AllergyFlag(trigger: .allergen(.milk),
                        members: [.init(id: nora.memberID, firstName: "Nora")],
                        ingredients: ["shredded cheddar cheese", "milk"]),
        ])
        #expect(flags.first?.summary == "Contains milk (Nora)")
    }

    @Test func groupsMembersAndSortsThemByName() throws {
        let flags = AllergyMatcher.flags(ingredients: ["pesto", "penne"], members: [owen, nora])
        #expect(flags.map(\.trigger) == [.allergen(.milk), .allergen(.treeNuts)])
        let milk = try #require(flags.first)
        #expect(milk.members.map(\.firstName) == ["Nora", "Owen"])
        #expect(milk.summary == "Contains milk (Nora, Owen)")
        #expect(flags.last?.summary == "Contains tree nuts (Nora)")
    }

    @Test func ordersFlagsByAllergenThenCustomText() {
        let both = MemberAllergies(memberID: UUID(), firstName: "Sam", allergens: [.wheat, .eggs],
                                   customTexts: ["cilantro", "Basil"])
        let flags = AllergyMatcher.flags(ingredients: ["cilantro", "egg noodles", "fresh basil"], members: [both])
        #expect(flags.map(\.trigger) == [.allergen(.eggs), .allergen(.wheat), .custom("Basil"), .custom("cilantro")])
    }

    @Test func listsEachMatchingIngredientOnceInMealOrder() {
        let flags = AllergyMatcher.flags(ingredients: ["butter", "flour", "milk", "butter"], members: [owen])
        #expect(flags.first?.ingredients == ["butter", "milk"])
    }

    @Test func customTextMatchesSingularOrPlural() {
        #expect(AllergyMatcher.flags(ingredients: ["strawberry jam"], members: [ada]).first?.summary
                == "Contains Strawberries (Ada)")
        let singular = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["strawberry"])
        #expect(AllergyMatcher.flags(ingredients: ["fresh strawberries"], members: [singular]).count == 1)
    }

    @Test func customTextMatchesWholeWordsOnly() {
        let corn = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["corn"])
        #expect(AllergyMatcher.flags(ingredients: ["popcorn", "acorn squash", "peppercorns"], members: [corn]).isEmpty)
        #expect(AllergyMatcher.flags(ingredients: ["Corn on the cob"], members: [corn]).count == 1)
    }

    @Test func multiWordCustomTextMatchesAsAPhrase() {
        let pepper = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["red pepper"])
        #expect(AllergyMatcher.flags(ingredients: ["red bell pepper"], members: [pepper]).isEmpty)
        #expect(AllergyMatcher.flags(ingredients: ["roasted red peppers"], members: [pepper]).count == 1)
    }

    @Test func sameCustomTextAcrossMembersIsOneFlag() {
        let twin = MemberAllergies(memberID: UUID(), firstName: "Bea", customTexts: ["strawberries "])
        let flags = AllergyMatcher.flags(ingredients: ["strawberries"], members: [twin, ada])
        #expect(flags.count == 1)
        #expect(flags.first?.members.map(\.firstName) == ["Ada", "Bea"])
    }

    @Test func blankCustomTextNeverMatches() {
        let blank = MemberAllergies(memberID: UUID(), firstName: "Bo", allergens: [.custom], customTexts: ["", "  "])
        #expect(AllergyMatcher.flags(ingredients: ["milk", "eggs", "anything"], members: [blank]).isEmpty)
    }

    @Test func emptyInputsHaveNoFlags() {
        #expect(AllergyMatcher.flags(ingredients: [], members: [nora, owen]).isEmpty)
        #expect(AllergyMatcher.flags(ingredients: ["milk", "pesto"], members: []).isEmpty)
        let none = MemberAllergies(memberID: UUID(), firstName: "Bo")
        #expect(AllergyMatcher.flags(ingredients: ["milk"], members: [none]).isEmpty)
    }

    @Test func allergensNoOneHasAreNotFlagged() {
        #expect(AllergyMatcher.flags(ingredients: ["shrimp", "soy sauce"], members: [nora, owen]).isEmpty)
    }

    @Test func sameInputInAnyMemberOrderGivesTheSameFlags() {
        let ingredients = ["caesar dressing", "parmesan cheese", "strawberries", "walnuts"]
        #expect(AllergyMatcher.flags(ingredients: ingredients, members: [nora, owen, ada])
                == AllergyMatcher.flags(ingredients: ingredients, members: [ada, owen, nora]))
    }
}

/// Every ingredient in the starter pack goes through the matcher; a hand-checked subset pins the tricky ones.
struct AllergyCatalogSeedTests {
    /// `Fixtures/catalog.sql` links to the real seed and ships in the test bundle: the sandboxed
    /// test host can't read the repo checkout directly.
    private final class BundleToken {}

    static func seedURL() throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: "catalog", withExtension: "sql"))
    }

    /// Seed entries are `'name|category|quantity'`.
    static func seedIngredients() throws -> [(name: String, category: String)] {
        let sql = try String(contentsOf: try seedURL(), encoding: .utf8)
        let entry = /'([^'|]+)\|([a-z_]+)\|[^']*'/
        return sql.matches(of: entry).map { (String($0.output.1), String($0.output.2)) }
    }

    static func seedIngredientNames() throws -> Set<String> {
        Set(try seedIngredients().map(\.name))
    }

    static let expected: [String: Set<Allergen>] = [
        "spaghetti": [.wheat],
        "pasta sauce": [],
        "frozen meatballs": [],
        "parmesan cheese": [.milk],
        "garlic bread": [.wheat],
        "egg noodles": [.eggs, .wheat],
        "butter": [.milk],
        "shredded cheddar cheese": [.milk],
        "breadcrumbs": [.wheat],
        "flour tortillas": [.wheat],
        "corn tortillas": [],
        "taco shells": [],
        "tortilla chips": [],
        "sour cream": [.milk],
        "cream cheese": [.milk],
        "mayonnaise": [.eggs],
        "pesto": [.milk, .treeNuts],
        "caesar dressing": [.eggs, .fish, .milk],
        "italian dressing": [],
        "alfredo sauce": [.milk],
        "crab meat": [.shellfish],
        "sea scallops": [.shellfish],
        "cod fillets": [.fish],
        "tartar sauce": [.eggs],
        "pancake and waffle mix": [.wheat],
        "pizza sauce": [],
        "pizza dough": [.wheat],
        "frozen pizza": [.milk, .wheat],
        "teriyaki sauce": [.soy, .wheat],
        "stir-fry sauce": [.soy, .wheat],
        "soy sauce": [.soy, .wheat],
        "edamame": [.soy],
        "box mac and cheese": [.milk, .wheat],
        "frozen fish sticks": [.fish, .wheat],
        "frozen dumplings": [.wheat],
        "frozen pierogies": [.wheat],
        "croissants": [.milk, .wheat],
        "butternut squash": [],
        "green beans": [],
        "chicken broth": [],
    ]

    @Test func seedHasTheIngredientsThisTestChecks() throws {
        let names = try Self.seedIngredientNames()
        #expect(names.count > 100)
        let missing = Set(Self.expected.keys).subtracting(names).subtracting(["butternut squash"])
        #expect(missing.isEmpty, "Not in the seed any more: \(missing.sorted())")
    }

    @Test func handCheckedSeedIngredientsMatch() {
        for (name, allergens) in Self.expected {
            #expect(AllergyMatcher.allergens(in: name) == allergens, "\(name)")
        }
    }

    @Test func everySeedIngredientMatchesWithoutSurprises() throws {
        let names = try Self.seedIngredientNames()
        for name in names {
            let found = AllergyMatcher.allergens(in: name)
            #expect(!found.contains(.custom), "\(name)")
            #expect(found == AllergyMatcher.allergens(in: name.uppercased()), "\(name)")
        }
    }

    @Test func everySeedDairyAndEggItemIsFlagged() throws {
        let dairy = try Self.seedIngredients().filter { $0.category == "dairy_eggs" }
        #expect(!dairy.isEmpty)
        for item in dairy {
            #expect(!AllergyMatcher.allergens(in: item.name).isDisjoint(with: [.milk, .eggs]), "\(item.name)")
        }
    }
}
