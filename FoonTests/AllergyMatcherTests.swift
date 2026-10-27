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

    @Test func everyStandardAllergenHasKeywords() {
        #expect(AllergenKeywords.all.map(\.allergen) == Allergen.allCases.filter { $0 != .custom })
        #expect(AllergenKeywords.all.allSatisfy { !$0.phrases.isEmpty })
    }

    /// One-word compounds: a missed allergen is far worse than an extra flag.
    static let compounds: [(String, Set<Allergen>)] = [
        ("cheesecake", [.milk, .eggs, .wheat]),
        ("cheeseburger", [.milk, .wheat]),
        ("cheesesteak", [.milk, .wheat]),
        ("buttercream frosting", [.milk]),
        ("cupcakes", [.wheat]),
        ("strawberry shortcake", [.wheat]),
        ("flatbread", [.wheat]),
        ("sourdough", [.wheat]),
        ("breadsticks", [.wheat]),
        ("doughnuts", [.wheat]),
        ("donut", [.wheat]),
        ("cornbread", [.milk, .eggs, .wheat]),
        ("crabmeat", [.shellfish]),
        ("crabcakes", [.shellfish, .wheat]),
        ("whitefish", [.fish]),
        ("monkfish", [.fish]),
        ("oatmilk", []),
        ("soymilk", [.soy]),
        ("almondmilk", [.treeNuts]),
        ("goldfish crackers", [.milk, .wheat]),
    ]

    @Test(arguments: compounds)
    func findsAllergensInsideCompoundWords(name: String, expected: Set<Allergen>) {
        #expect(AllergyMatcher.allergens(in: name) == expected)
    }

    static let moreKeywords: [(String, Set<Allergen>)] = [
        ("mascarpone", [.milk]), ("paneer", [.milk]), ("cotija", [.milk]), ("romano", [.milk]),
        ("asiago", [.milk]), ("gruyère", [.milk]), ("gruyere", [.milk]), ("monterey jack", [.milk]),
        ("chicken parm", [.milk]), ("tzatziki", [.milk]), ("béchamel", [.milk]), ("chocolate pudding", [.milk]),
        ("kefir", [.milk]), ("crème fraîche", [.milk]), ("fromage blanc", [.milk]), ("creme brulee", [.milk, .eggs]),
        ("Half & Half", [.milk]), ("non-dairy creamer", [.milk]), ("whipped topping", [.milk]),
        ("hollandaise", [.milk, .eggs]), ("lemon curd", [.milk, .eggs]), ("egg yolks", [.eggs]), ("yolks", [.eggs]),
        ("quiche", [.milk, .eggs, .wheat]), ("frittata", [.eggs]), ("carbonara sauce", [.milk, .eggs]),
        ("eggs, free-range", [.eggs]), ("free range eggs", [.eggs]), ("cage free eggs", [.eggs]),
        ("free-roaming eggs", [.eggs]),
        ("mackerel", [.fish]), ("herring", [.fish]), ("striped bass", [.fish]), ("lox", [.fish]),
        ("caviar", [.fish]), ("imitation crab", [.fish, .shellfish]),
        ("langostino", [.shellfish]), ("shrimp scampi", [.shellfish]), ("fried calamari", [.shellfish]),
        ("squid", [.shellfish]), ("octopus", [.shellfish]),
        ("baklava", [.treeNuts, .wheat]),
        ("nuts", [.treeNuts, .peanuts]), ("chopped nuts", [.treeNuts, .peanuts]),
        ("nut butter", [.treeNuts, .peanuts]),
        ("farro", [.wheat]), ("udon noodles", [.wheat]), ("ramen", [.wheat]), ("matzo", [.wheat]),
        ("matzah ball soup", [.wheat]), ("puff pastry", [.wheat]), ("lasagne", [.wheat]), ("farfalle", [.wheat]),
        ("fusilli", [.wheat]), ("crêpes", [.milk, .eggs, .wheat]), ("phyllo dough", [.wheat]),
        ("shoyu", [.soy, .wheat]), ("ponzu", [.soy, .wheat]),
    ]

    @Test(arguments: moreKeywords)
    func findsLessCommonNames(name: String, expected: Set<Allergen>) {
        #expect(AllergyMatcher.allergens(in: name) == expected)
    }

    static let compoundLookalikes: [(String, Set<Allergen>)] = [
        ("breadfruit", []),
        ("buckwheat", []),
        ("cheesecloth", []),
        ("butterfly shrimp", [.shellfish]),
        ("buttercup squash", []),
        ("butterhead lettuce", []),
        ("crawfish", [.shellfish]),
        ("shellfish", [.shellfish]),
        ("crabapple", []),
        ("creme de menthe", []),
        ("pine nuts", [.treeNuts]),
        ("brazil nuts", [.treeNuts]),
        ("eggless cookies", [.wheat]),
    ]

    @Test(arguments: compoundLookalikes)
    func compoundLookalikesOnlyFlagWhatTheyAre(name: String, expected: Set<Allergen>) {
        #expect(AllergyMatcher.allergens(in: name) == expected)
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

    @Test func customTextMatchesTheStartOfAWord() {
        let corn = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["corn"])
        #expect(AllergyMatcher.flags(ingredients: ["popcorn", "acorn squash", "peppercorns"], members: [corn]).isEmpty)
        let flags = AllergyMatcher.flags(ingredients: ["Corn on the cob", "cornstarch", "cornmeal"], members: [corn])
        #expect(flags.first?.ingredients == ["Corn on the cob", "cornstarch", "cornmeal"])
        let oat = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["oat"])
        #expect(AllergyMatcher.flags(ingredients: ["oatmeal"], members: [oat]).count == 1)
        let kiwi = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["kiwi"])
        #expect(AllergyMatcher.flags(ingredients: ["kiwifruit"], members: [kiwi]).count == 1)
    }

    static let categoryWords: [(String, [AllergyFlag.Trigger])] = [
        ("gluten", [.allergen(.wheat)]),
        ("Wheat", [.allergen(.wheat)]),
        ("dairy", [.allergen(.milk)]),
        ("lactose", [.allergen(.milk)]),
        ("nuts", [.allergen(.treeNuts), .allergen(.peanuts)]),
        ("tree nuts", [.allergen(.treeNuts), .allergen(.peanuts)]),
        ("nut", [.allergen(.treeNuts), .allergen(.peanuts)]),
        ("shellfish", [.allergen(.shellfish)]),
        ("seafood", [.allergen(.fish), .allergen(.shellfish)]),
        ("egg", [.allergen(.eggs), .custom("egg")]),
    ]

    /// Guardians type category words under Other; they mean the real allergen, plus the literal text.
    @Test(arguments: categoryWords)
    func customCategoryWordsAlsoFlagTheRealAllergen(text: String, expected: [AllergyFlag.Trigger]) {
        let member = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: [text])
        let ingredients = ["flour", "butter", "walnuts", "peanuts", "shrimp", "salmon", "eggs"]
        #expect(AllergyMatcher.flags(ingredients: ingredients, members: [member]).map(\.trigger) == expected)
    }

    @Test func mappedAllergenJoinsTheSameFlagAsTheChip() {
        let chip = MemberAllergies(memberID: UUID(), firstName: "Ada", allergens: [.milk])
        let typed = MemberAllergies(memberID: UUID(), firstName: "Bo", customTexts: ["Dairy"])
        let flags = AllergyMatcher.flags(ingredients: ["butter"], members: [typed, chip])
        #expect(flags.map(\.summary) == ["Contains milk (Ada, Bo)"])
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

/// Every ingredient in the starter pack goes through the matcher and is pinned to a hand-checked expectation.
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
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
        let entry = /'([^'|]+)\|([a-z_]+)\|[^']*'/
        return sql.matches(of: entry).map { (String($0.output.1), String($0.output.2)) }
    }

    static func seedIngredientNames() throws -> Set<String> {
        Set(try seedIngredients().map(\.name))
    }

    /// Every distinct ingredient name in the seed and what it should flag, hand-checked. A keyword change
    /// that moves any of these shows up here in review; a new seed ingredient has to be added here.
    static let snapshot: [String: Set<Allergen>] = [
        "alfredo sauce": [.milk],
        "angel hair pasta": [.wheat],
        "applesauce": [],
        "asparagus": [],
        "avocados": [],
        "bacon": [],
        "bbq sauce": [],
        "beef broth": [],
        "beef chuck roast": [],
        "beef stew meat": [],
        "bell pepper": [],
        "bell peppers": [],
        "berries": [],
        "black beans": [],
        "box mac and cheese": [.milk, .wheat],
        "brat buns": [.wheat],
        "bratwurst": [],
        "bread": [.wheat],
        "breadcrumbs": [.wheat],
        "breakfast sausage": [],
        "broccoli": [],
        "butter": [.milk],
        "cabbage": [],
        "caesar dressing": [.milk, .eggs, .fish],
        "carrots": [],
        "celery": [],
        "cherry tomatoes": [],
        "chicken breasts": [],
        "chicken broth": [],
        "chicken thighs": [],
        "chili seasoning": [],
        "chips": [],
        "ciabatta bread": [.wheat],
        "cinnamon": [],
        "cod fillets": [.fish],
        "coleslaw mix": [],
        "corn": [],
        "corn on the cob": [],
        "corn tortillas": [],
        "crab meat": [.shellfish],
        "cream cheese": [.milk],
        "croissants": [.milk, .wheat],
        "cucumber": [],
        "deli ham": [],
        "deli turkey": [],
        "diced tomatoes": [],
        "dinner rolls": [.wheat],
        "edamame": [.soy],
        "egg noodles": [.eggs, .wheat],
        "eggs": [.eggs],
        "elbow macaroni": [.wheat],
        "enchilada sauce": [],
        "english muffins": [.wheat],
        "fettuccine": [.wheat],
        "flank steak": [],
        "flour": [.wheat],
        "flour tortillas": [.wheat],
        "frozen chicken nuggets": [.wheat],
        "frozen dumplings": [.wheat],
        "frozen fish sticks": [.fish, .wheat],
        "frozen fries": [],
        "frozen hash browns": [],
        "frozen meatballs": [.milk, .eggs, .wheat],
        "frozen pierogies": [.milk, .eggs, .wheat],
        "frozen pizza": [.milk, .wheat],
        "frozen tater tots": [],
        "garlic": [],
        "garlic bread": [.milk, .wheat],
        "grapes": [],
        "great northern beans": [],
        "green beans": [],
        "green chiles": [],
        "green onions": [],
        "ground beef": [],
        "ham steak": [],
        "hamburger buns": [.wheat],
        "hoagie rolls": [.wheat],
        "hot dog buns": [.wheat],
        "hot dogs": [],
        "italian dressing": [],
        "italian sausage": [],
        "jalapenos": [],
        "ketchup": [],
        "kidney beans": [],
        "lasagna noodles": [.wheat],
        "lemon": [],
        "lettuce": [],
        "limes": [],
        "maple syrup": [],
        "mayonnaise": [.eggs],
        "milk": [.milk],
        "mixed vegetables": [],
        "mustard": [],
        "olive oil": [],
        "onion": [],
        "onion soup mix": [],
        "pancake and waffle mix": [.wheat],
        "pancake mix": [.wheat],
        "parmesan cheese": [.milk],
        "pasta sauce": [],
        "penne": [.wheat],
        "pepperoni": [],
        "pesto": [.milk, .treeNuts],
        "pizza dough": [.wheat],
        "pizza sauce": [],
        "pork chops": [],
        "pork shoulder": [],
        "pork tenderloin": [],
        "potatoes": [],
        "provolone cheese": [.milk],
        "rice": [],
        "ricotta cheese": [.milk],
        "romaine lettuce": [],
        "rotisserie chicken": [],
        "russet potatoes": [],
        "salad greens": [],
        "salami": [],
        "salmon fillets": [.fish],
        "salsa": [],
        "sauerkraut": [],
        "sea scallops": [.shellfish],
        "shredded cheddar cheese": [.milk],
        "shredded mozzarella cheese": [.milk],
        "shrimp": [.shellfish],
        "sirloin steak": [],
        "sliced cheese": [.milk],
        "sloppy joe sauce": [],
        "small pasta": [.wheat],
        "smoked sausage": [],
        "sour cream": [.milk],
        "soy sauce": [.wheat, .soy],
        "spaghetti": [.wheat],
        "steak seasoning": [],
        "steaks": [],
        "stir-fry sauce": [.wheat, .soy],
        "stir-fry vegetables": [],
        "sub rolls": [.wheat],
        "taco seasoning": [],
        "taco shells": [],
        "tartar sauce": [.eggs],
        "teriyaki sauce": [.wheat, .soy],
        "tilapia fillets": [.fish],
        "tomato sauce": [],
        "tomato soup": [],
        "tomatoes": [],
        "tortilla chips": [],
        "vegetable broth": [],
        "ziti": [.wheat],
        "zucchini": [],
    ]

    @Test func snapshotCoversEverySeedIngredient() throws {
        let names = try Self.seedIngredientNames()
        #expect(names.count > 100)
        let missing = names.subtracting(Self.snapshot.keys)
        let gone = Set(Self.snapshot.keys).subtracting(names)
        #expect(missing.isEmpty, "Seed ingredients with no expectation: \(missing.sorted())")
        #expect(gone.isEmpty, "Not in the seed any more: \(gone.sorted())")
    }

    @Test func everySeedIngredientMatchesTheSnapshot() {
        for (name, allergens) in Self.snapshot.sorted(by: { $0.key < $1.key }) {
            #expect(AllergyMatcher.allergens(in: name) == allergens, "\(name)")
            #expect(AllergyMatcher.allergens(in: name.uppercased()) == allergens, "\(name), uppercased")
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
