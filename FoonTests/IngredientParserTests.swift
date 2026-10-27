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
        ("2 oz. cream cheese", "2 oz.", "cream cheese")
    ])
    func readsLeadingNumbers(text: String, quantity: String, name: String) {
        #expect(IngredientParser.parse(text) == [item(name, quantity)])
    }

    @Test(arguments: [
        "lb", "lbs", "pound", "pounds", "oz", "ounce", "ounces", "g", "kg", "ml", "l",
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
        "can", "cans", "jar", "jars", "bag", "bags", "box", "boxes", "pack", "packs", "package", "packages",
        "bottle", "bottles", "clove", "cloves", "bunch", "bunches", "head", "heads", "pint", "pints",
        "dozen", "slice", "slices", "stick", "sticks", "pinch"
    ])
    func recognizesEveryUnit(unit: String) {
        #expect(IngredientParser.parse("2 \(unit) thing") == [item("thing", "2 \(unit)")])
        #expect(IngredientParser.parse("2 \(unit.uppercased()) thing") == [item("thing", "2 \(unit.uppercased())")])
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
