import Testing
@testable import Foon

private func item(_ name: String, _ quantity: String? = nil) -> ParsedIngredient {
    ParsedIngredient(name: name, quantity: quantity)
}

struct IngredientParserSplittingTests {
    @Test func parsesTheIssueExample() {
        #expect(IngredientParser.parse("1 lb ground beef, taco shells, cheese") == [
            item("ground beef", "1 lb"),
            item("taco shells"),
            item("cheese")
        ])
    }

    @Test func splitsOnCommasSemicolonsAndNewlines() {
        #expect(IngredientParser.parse("milk; eggs\nbread,butter\r\njam") == [
            item("milk"), item("eggs"), item("bread"), item("butter"), item("jam")
        ])
    }

    @Test func stripsBulletsAtLineStarts() {
        let text = """
        - 2 cans black beans
        * rice
        • salsa
          -   sour cream
        """
        #expect(IngredientParser.parse(text) == [
            item("black beans", "2 cans"), item("rice"), item("salsa"), item("sour cream")
        ])
    }

    @Test func splitsOnInlineBulletDots() {
        #expect(IngredientParser.parse("milk • eggs • bread") == [item("milk"), item("eggs"), item("bread")])
    }

    @Test func keepsHyphenatedNamesWhole() {
        #expect(IngredientParser.parse("stir-fry sauce, 7-up, 5-spice powder, 3-bean chili") == [
            item("stir-fry sauce"), item("7-up"), item("5-spice powder"), item("3-bean chili")
        ])
    }

    @Test(arguments: ["mac and cheese", "salt and pepper", "pancake and waffle mix"])
    func neverSplitsOnAnd(name: String) {
        #expect(IngredientParser.parse(name) == [item(name)])
    }

    @Test func keepsCommasInsideParenthesesTogether() {
        #expect(IngredientParser.parse("1 (14.5 oz, diced) can tomatoes, basil") == [
            item("tomatoes", "1 (14.5 oz, diced) can"), item("basil")
        ])
    }

    @Test func collapsesMessyWhitespaceAndStripsTrailingPeriods() {
        #expect(IngredientParser.parse("   1   lb    ground  beef.  ,,  ,\t taco\tshells...  \n\n") == [
            item("ground beef", "1 lb"), item("taco shells")
        ])
    }

    @Test func keepsOriginalCasing() {
        #expect(IngredientParser.parse("2 Cans San Marzano Tomatoes") == [item("San Marzano Tomatoes", "2 Cans")])
    }

    @Test(arguments: ["", "   ", "\n\n", ",,,", " ; , \n • - * ", "...", "!!!", "-", "()"])
    func returnsNothingForEmptyOrPunctuationOnlyInput(text: String) {
        #expect(IngredientParser.parse(text).isEmpty)
    }

    @Test func handlesVeryLongInput() {
        let text = Array(repeating: "1 lb ground beef, taco shells", count: 5_000).joined(separator: "\n")
        let parsed = IngredientParser.parse(text)
        #expect(parsed.count == 10_000)
        #expect(parsed.first == item("ground beef", "1 lb"))
        #expect(parsed.last == item("taco shells"))
    }

    @Test func handlesOneHugeFragment() {
        let name = String(repeating: "a", count: 100_000)
        #expect(IngredientParser.parse("3 cups \(name)") == [item(name, "3 cups")])
    }

    @Test(arguments: ["(((", ")))", "1 (", "1 (15 oz", "½", "1/", "1/2/3 eggs", "2-", "🌮🌮", "e\u{301}clair",
                      "1 1/ cup", "\u{0}", "1..5 lb", "1-2-3 eggs", "1 (15 oz can beans, rice"])
    func survivesOddInputWithoutEmptyNames(text: String) {
        #expect(IngredientParser.parse(text).allSatisfy { !$0.name.isEmpty })
    }

    @Test func unclosedParenthesesStillSplit() {
        #expect(IngredientParser.parse("1 (15 oz can beans, rice") == [item("(15 oz can beans", "1"), item("rice")])
    }

    @Test func treatsALeadingDashAsABullet() {
        #expect(IngredientParser.parse("-3 eggs") == [item("eggs", "3")])
    }

    @Test func isDeterministic() {
        let text = "1 lb beef, ½ cup milk\n- 2-3 cloves garlic; a dozen eggs"
        #expect(IngredientParser.parse(text) == IngredientParser.parse(text))
    }
}

struct IngredientParserQuantityTests {
    @Test(arguments: [
        ("3 eggs", "3", "eggs"),
        ("1.5 lb chicken", "1.5 lb", "chicken"),
        ("1/2 cup sugar", "1/2 cup", "sugar"),
        ("1 1/2 cups flour", "1 1/2 cups", "flour"),
        ("½ cup milk", "½ cup", "milk"),
        ("1½ cups rice", "1½ cups", "rice"),
        ("1 ½ cups rice", "1 ½ cups", "rice"),
        ("¼ tsp salt", "¼ tsp", "salt"),
        ("¾ cup oats", "¾ cup", "oats"),
        ("⅓ cup oil", "⅓ cup", "oil"),
        ("⅔ cup water", "⅔ cup", "water"),
        ("2-3 cloves garlic", "2-3 cloves", "garlic"),
        ("2 - 3 cloves garlic", "2 - 3 cloves", "garlic"),
        ("2–3 tomatoes", "2–3", "tomatoes"),
        ("1/2-1 cup broth", "1/2-1 cup", "broth"),
        ("1 (15 oz) can black beans", "1 (15 oz) can", "black beans"),
        ("2 (28-ounce) cans crushed tomatoes", "2 (28-ounce) cans", "crushed tomatoes"),
        ("1lb ground turkey", "1lb", "ground turkey"),
        ("500g pasta", "500g", "pasta"),
        ("2 oz. cream cheese", "2 oz.", "cream cheese"),
        ("1 can (15 oz) black beans", "1 can (15 oz)", "black beans"),
        ("2 cups (480 ml) broth", "2 cups (480 ml)", "broth"),
        ("1 cup (8 oz.) sour cream", "1 cup (8 oz.)", "sour cream"),
        ("1 (15 oz) can (drained) beans", "1 (15 oz) can", "(drained) beans"),
        ("2 cans (15 oz each) of beans", "2 cans (15 oz each)", "beans")
    ])
    func readsLeadingNumbers(text: String, quantity: String, name: String) {
        #expect(IngredientParser.parse(text) == [item(name, quantity)])
    }

    @Test(arguments: [
        "lb", "lbs", "pound", "pounds", "oz", "ounce", "ounces", "g", "kg", "ml", "l",
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
        "can", "cans", "jar", "jars", "bag", "bags", "box", "boxes", "pack", "packs", "package", "packages",
        "bottle", "bottles", "clove", "cloves", "bunch", "bunches", "head", "heads", "pint", "pints",
        "dozen", "slice", "slices", "stick", "sticks", "pinch",
        "loaf", "loaves", "carton", "cartons", "packet", "packets", "stalk", "stalks",
        "gallon", "gallons", "gal", "quart", "quarts", "qt", "pt", "pkg",
        "container", "containers", "piece", "pieces"
    ])
    func recognizesEveryUnit(unit: String) {
        #expect(IngredientParser.parse("2 \(unit) thing") == [item("thing", "2 \(unit)")])
        #expect(IngredientParser.parse("2 \(unit.uppercased()) thing") == [item("thing", "2 \(unit.uppercased())")])
    }

    @Test(arguments: catalogQuantities)
    func separatesEveryStarterCatalogQuantity(quantity: String, name: String) {
        #expect(IngredientParser.parse("\(quantity) \(name)") == [item(name, quantity)])
    }

    @Test func leavesAmbiguousSingleLetterUnitsInTheName() {
        #expect(IngredientParser.parse("1 T butter") == [item("T butter", "1")])
        #expect(IngredientParser.parse("2 c flour") == [item("c flour", "2")])
    }

    @Test func leavesNonUnitWordsInTheName() {
        #expect(IngredientParser.parse("2 large eggs") == [item("large eggs", "2")])
        #expect(IngredientParser.parse("2 garlic bulbs") == [item("garlic bulbs", "2")])
        #expect(IngredientParser.parse("4 lemons") == [item("lemons", "4")])
    }

    @Test func dropsOfAfterAUnit() {
        #expect(IngredientParser.parse("2 cups of flour") == [item("flour", "2 cups")])
        #expect(IngredientParser.parse("a pinch of salt") == [item("salt", "a pinch")])
    }

    @Test func readsArticlesWithUnits() {
        #expect(IngredientParser.parse("a dozen eggs") == [item("eggs", "a dozen")])
        #expect(IngredientParser.parse("A can of tomatoes") == [item("tomatoes", "A can")])
        #expect(IngredientParser.parse("a bag of chips") == [item("chips", "a bag")])
        #expect(IngredientParser.parse("2 dozen eggs") == [item("eggs", "2 dozen")])
    }

    @Test func dropsVagueWordsWithoutInventingAQuantity() {
        #expect(IngredientParser.parse("a lemon") == [item("lemon")])
        #expect(IngredientParser.parse("an onion") == [item("onion")])
        #expect(IngredientParser.parse("some cheese") == [item("cheese")])
        #expect(IngredientParser.parse("Some parmesan") == [item("parmesan")])
    }

    @Test func readsAFewAndACouple() {
        #expect(IngredientParser.parse("a few limes") == [item("limes", "a few")])
        #expect(IngredientParser.parse("a couple of avocados") == [item("avocados", "a couple")])
    }

    @Test func neverInventsAQuantity() {
        #expect(IngredientParser.parse("taco shells") == [item("taco shells")])
        #expect(IngredientParser.parse("7up") == [item("7up")])
        #expect(IngredientParser.parse("2nd-day bread") == [item("2nd-day bread")])
        #expect(IngredientParser.parse("A1 sauce") == [item("A1 sauce")])
        #expect(IngredientParser.parse("canola oil") == [item("canola oil")])
    }

    @Test func keepsTheTextWhenNothingFollowsTheQuantity() {
        #expect(IngredientParser.parse("3") == [item("3")])
        #expect(IngredientParser.parse("2 cups") == [item("2 cups")])
        #expect(IngredientParser.parse("a") == [item("a")])
        #expect(IngredientParser.parse("some") == [item("some")])
    }

    @Test func ignoresParenthesesWithoutASize() {
        #expect(IngredientParser.parse("2 (optional) jalapeños") == [item("(optional) jalapeños", "2")])
    }
}

struct IngredientAutocompleteTests {
    private let items = ["Ground beef", "beef broth", "Beef", "corned beef", "Beefsteak tomatoes",
                         "broccoli", "roast beef", "taco shells"]

    @Test func ordersExactThenPrefixThenWordPrefixEachAlphabetically() {
        #expect(IngredientAutocomplete.suggestions(for: "beef", from: items, limit: 10) == [
            "Beef", "beef broth", "Beefsteak tomatoes", "corned beef", "Ground beef", "roast beef"
        ])
    }

    @Test func respectsTheLimit() {
        #expect(IngredientAutocomplete.suggestions(for: "beef", from: items) == [
            "Beef", "beef broth", "Beefsteak tomatoes", "corned beef", "Ground beef"
        ])
        #expect(IngredientAutocomplete.suggestions(for: "beef", from: items, limit: 2) == ["Beef", "beef broth"])
        #expect(IngredientAutocomplete.suggestions(for: "beef", from: items, limit: 0).isEmpty)
        #expect(IngredientAutocomplete.suggestions(for: "beef", from: items, limit: -1).isEmpty)
    }

    @Test func ignoresCaseAndWhitespace() {
        #expect(IngredientAutocomplete.suggestions(for: "  GROUND   b ", from: items) == ["Ground beef"])
        #expect(IngredientAutocomplete.suggestions(for: "taco s", from: ["  taco   shells "]) == ["taco shells"])
    }

    @Test func matchesMultiWordPrefixesInsideNames() {
        #expect(IngredientAutocomplete.suggestions(for: "beef br", from: items) == ["beef broth"])
        #expect(IngredientAutocomplete.suggestions(for: "shells", from: items) == ["taco shells"])
    }

    @Test func doesNotMatchTheMiddleOfAWord() {
        #expect(IngredientAutocomplete.suggestions(for: "eef", from: items).isEmpty)
        #expect(IngredientAutocomplete.suggestions(for: "coli", from: items).isEmpty)
    }

    @Test func aCommaInsideClosedParenthesesDoesntStartAFragment() {
        #expect(IngredientAutocomplete.typing(in: "1 cup flour (sifted, twice) su") == "flour (sifted, twice) su")
        #expect(IngredientAutocomplete.typing(in: "1 cup flour (sifted; twice) su") == "flour (sifted; twice) su")
        #expect(IngredientAutocomplete.typing(in: "1 cup flour (sifted), su") == "su")
    }

    @Test func removesCaseInsensitiveDuplicatesKeepingTheFirstSpelling() {
        let names = ["Milk", "milk", " MILK ", "milk chocolate", "Milk  Chocolate"]
        #expect(IngredientAutocomplete.suggestions(for: "mil", from: names) == ["Milk", "milk chocolate"])
    }

    @Test(arguments: ["", "   ", "\n"])
    func returnsNothingForAnEmptyPrefix(prefix: String) {
        #expect(IngredientAutocomplete.suggestions(for: prefix, from: items).isEmpty)
    }

    @Test func skipsBlankItemNames() {
        #expect(IngredientAutocomplete.suggestions(for: "a", from: ["", "  ", "apple"]) == ["apple"])
    }
}

/// Every distinct quantity and name pair in supabase/seed/catalog.sql, so starter dishes typed by hand parse cleanly.
private let catalogQuantities: [(quantity: String, name: String)] = [
    ("1", "bell pepper"),
    ("1", "cucumber"),
    ("1", "eggs"),
    ("1", "ham steak"),
    ("1", "lemon"),
    ("1", "onion"),
    ("1", "rotisserie chicken"),
    ("1", "zucchini"),
    ("1 bag", "chips"),
    ("1 bag", "coleslaw mix"),
    ("1 bag", "corn"),
    ("1 bag", "edamame"),
    ("1 bag", "frozen chicken nuggets"),
    ("1 bag", "frozen dumplings"),
    ("1 bag", "frozen fries"),
    ("1 bag", "frozen hash browns"),
    ("1 bag", "frozen meatballs"),
    ("1 bag", "frozen tater tots"),
    ("1 bag", "green beans"),
    ("1 bag", "mixed vegetables"),
    ("1 bag", "salad greens"),
    ("1 bag", "stir-fry vegetables"),
    ("1 bag", "tortilla chips"),
    ("1 bottle", "bbq sauce"),
    ("1 bottle", "italian dressing"),
    ("1 bottle", "stir-fry sauce"),
    ("1 bottle", "teriyaki sauce"),
    ("1 box", "frozen fish sticks"),
    ("1 box", "frozen pierogies"),
    ("1 box", "lasagna noodles"),
    ("1 box", "pancake and waffle mix"),
    ("1 box", "pancake mix"),
    ("1 box", "taco shells"),
    ("1 bunch", "asparagus"),
    ("1 bunch", "green onions"),
    ("1 can", "black beans"),
    ("1 can", "diced tomatoes"),
    ("1 can", "green chiles"),
    ("1 can", "kidney beans"),
    ("1 can", "sloppy joe sauce"),
    ("1 can", "tomato sauce"),
    ("1 carton", "beef broth"),
    ("1 carton", "chicken broth"),
    ("1 carton", "vegetable broth"),
    ("1 cup", "beef broth"),
    ("1 cup", "breadcrumbs"),
    ("1 cup", "flour"),
    ("1 cup", "grapes"),
    ("1 cup", "milk"),
    ("1 cup", "small pasta"),
    ("1 head", "broccoli"),
    ("1 head", "romaine lettuce"),
    ("1 jar", "alfredo sauce"),
    ("1 jar", "applesauce"),
    ("1 jar", "pasta sauce"),
    ("1 jar", "pesto"),
    ("1 jar", "pizza sauce"),
    ("1 jar", "salsa"),
    ("1 jar", "sauerkraut"),
    ("1 lb", "angel hair pasta"),
    ("1 lb", "bacon"),
    ("1 lb", "breakfast sausage"),
    ("1 lb", "chicken breasts"),
    ("1 lb", "chicken thighs"),
    ("1 lb", "crab meat"),
    ("1 lb", "elbow macaroni"),
    ("1 lb", "fettuccine"),
    ("1 lb", "flank steak"),
    ("1 lb", "ground beef"),
    ("1 lb", "italian sausage"),
    ("1 lb", "penne"),
    ("1 lb", "sea scallops"),
    ("1 lb", "shrimp"),
    ("1 lb", "smoked sausage"),
    ("1 lb", "spaghetti"),
    ("1 lb", "ziti"),
    ("1 loaf", "bread"),
    ("1 loaf", "ciabatta bread"),
    ("1 loaf", "garlic bread"),
    ("1 pack", "brat buns"),
    ("1 pack", "bratwurst"),
    ("1 pack", "dinner rolls"),
    ("1 pack", "english muffins"),
    ("1 pack", "hot dog buns"),
    ("1 pack", "hot dogs"),
    ("1 pack", "pepperoni"),
    ("1 packet", "chili seasoning"),
    ("1 packet", "onion soup mix"),
    ("1 packet", "taco seasoning"),
    ("1 pint", "berries"),
    ("1 pint", "cherry tomatoes"),
    ("1.5 lb", "chicken breasts"),
    ("1.5 lb", "chicken thighs"),
    ("1.5 lb", "cod fillets"),
    ("1.5 lb", "ground beef"),
    ("1.5 lb", "sirloin steak"),
    ("1/2 cup", "breadcrumbs"),
    ("1/2 cup", "milk"),
    ("1/2 head", "cabbage"),
    ("1/2 lb", "bacon"),
    ("1/2 lb", "deli ham"),
    ("1/2 lb", "deli turkey"),
    ("1/2 lb", "salami"),
    ("1/4 cup", "flour"),
    ("10", "flour tortillas"),
    ("12", "corn tortillas"),
    ("12 oz", "egg noodles"),
    ("15 oz", "ricotta cheese"),
    ("2", "avocados"),
    ("2", "bell peppers"),
    ("2", "carrots"),
    ("2", "eggs"),
    ("2", "frozen pizza"),
    ("2", "jalapenos"),
    ("2", "limes"),
    ("2", "pizza dough"),
    ("2", "pork tenderloin"),
    ("2", "tomatoes"),
    ("2 boxes", "box mac and cheese"),
    ("2 cans", "diced tomatoes"),
    ("2 cans", "enchilada sauce"),
    ("2 cans", "great northern beans"),
    ("2 cans", "kidney beans"),
    ("2 cans", "tomato soup"),
    ("2 cartons", "chicken broth"),
    ("2 cups", "beef broth"),
    ("2 cups", "milk"),
    ("2 cups", "rice"),
    ("2 cups", "shredded cheddar cheese"),
    ("2 cups", "shredded mozzarella cheese"),
    ("2 heads", "broccoli"),
    ("2 jars", "pasta sauce"),
    ("2 lb", "beef stew meat"),
    ("2 lb", "chicken breasts"),
    ("2 lb", "chicken thighs"),
    ("2 lb", "ground beef"),
    ("2 stalks", "celery"),
    ("2 tbsp", "butter"),
    ("2 tbsp", "flour"),
    ("3", "carrots"),
    ("3 cups", "shredded cheddar cheese"),
    ("3 cups", "shredded mozzarella cheese"),
    ("3 lb", "beef chuck roast"),
    ("3 lb", "potatoes"),
    ("3 stalks", "celery"),
    ("3 tbsp", "butter"),
    ("3 tbsp", "flour"),
    ("4", "carrots"),
    ("4", "corn on the cob"),
    ("4", "croissants"),
    ("4", "eggs"),
    ("4", "flour tortillas"),
    ("4", "pork chops"),
    ("4", "potatoes"),
    ("4", "salmon fillets"),
    ("4", "steaks"),
    ("4", "sub rolls"),
    ("4", "tilapia fillets"),
    ("4 lb", "pork shoulder"),
    ("4 tbsp", "butter"),
    ("6", "hoagie rolls"),
    ("6", "potatoes"),
    ("6", "russet potatoes"),
    ("8", "eggs"),
    ("8", "flour tortillas"),
    ("8", "hamburger buns"),
    ("8 oz", "cream cheese"),
    ("8 oz", "egg noodles")
]
