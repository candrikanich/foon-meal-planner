import Foundation
import Synchronization
import Testing
@testable import Foon

struct QuantityScalerTests {
    @Test(arguments: [
        ("1 lb", 2.0, "2 lb"),
        ("1/2 cup", 1.5, "3/4 cup"),
        ("1 1/2 cups", 2.0, "3 cups"),
        ("½ tsp", 2.0, "1 tsp"),
        ("1½ cups", 0.5, "3/4 cups"),
        ("2-3 cloves", 2.0, "4-6 cloves"),
        ("1 (15 oz) can", 2.0, "2 (15 oz) can"),
        ("1.5 lb", 1.0 / 3.0, "1/2 lb"),
        ("3", 1.25, "3 3/4"),
        ("4", 1.0 / 3.0, "1 1/3"),
        ("2 tbsp", 0.3, "0.6 tbsp"),
        ("1-1/2 cups", 2.0, "3 cups"),
        ("1/8 tsp", 0.25, "1/8 tsp"),
        ("1/4 tsp", 0.5, "1/8 tsp")
    ])
    func scalesTheLeadingAmount(quantity: String, factor: Double, expected: String) {
        #expect(QuantityScaler.scale(quantity, by: factor) == expected)
    }

    @Test func leavesWordsAndUnscaledAmountsAlone() {
        #expect(QuantityScaler.scale("a dozen", by: 2) == "a dozen")
        #expect(QuantityScaler.scale("to taste", by: 2) == "to taste")
        #expect(QuantityScaler.scale("1 1/2 cups", by: 1) == "1 1/2 cups")
    }
}

struct RecipeImportTests {
    private let url = URL(string: "https://recipes.example/chili")!

    private func imported(servings: Int?, ingredients: [String] = ["1 lb ground beef"]) -> RecipeImport {
        RecipeImport(recipe: .init(name: "Weeknight Chili", servings: servings, ingredients: ingredients,
                                   steps: ["Brown the beef.", "Simmer."], imageURL: nil),
                     title: "Weeknight Chili | Blog", url: url)
    }

    @Test func scaledToTheHouseholdWithTheLinkKept() throws {
        let draft = imported(servings: 4, ingredients: ["1 lb ground beef", "1 (15 oz) can kidney beans, drained",
                                                         "salt to taste"])
            .draft(householdSize: 6)
        #expect(draft.name == "Weeknight Chili")
        #expect(draft.servings == 6)
        #expect(draft.link == "https://recipes.example/chili")
        #expect(draft.lines.map(\.quantity) == ["1 1/2 lb", "1 1/2 (15 oz) can", ""])
        #expect(draft.lines.map(\.name) == ["ground beef", "kidney beans, drained", "salt to taste"],
                "a recipe line is one ingredient, commas and all")
        #expect(draft.stepsText == "Brown the beef.\nSimmer.")
        _ = try draft.validated()
    }

    @Test func unknownServingsIsNotScaled() {
        let draft = imported(servings: nil).draft(householdSize: 3)
        #expect(draft.servings == 3)
        #expect(draft.lines.first?.quantity == "1 lb")
    }

    @Test func longLinesStillSave() throws {
        let long = "2 cups " + String(repeating: "very ", count: 15) + "finely chopped onion, about 2 medium"
        let draft = imported(servings: 4, ingredients: [long]).draft(householdSize: 4)
        #expect(MealDraft.length(draft.lines[0].name) <= 60)
        _ = try draft.validated()
    }

    @Test func noRecipeDataKeepsTheTitleAndLink() throws {
        let draft = RecipeImport(recipe: nil, title: "Grandma's Pot Roast", url: url).draft(householdSize: 4)
        #expect(draft.name == "Grandma's Pot Roast")
        #expect(draft.link == url.absoluteString)
        #expect(draft.lines.isEmpty)
        _ = try draft.validated()
        let untitled = RecipeImport(recipe: nil, title: nil, url: url).draft(householdSize: 4)
        #expect(untitled.name == "recipes.example")
    }

    @Test func aVeryLongFinalLinkLosesItsQueryAndStillSaves() throws {
        let long = URL(string: "https://recipes.example/chili?" + String(repeating: "utm=x&", count: 400))!
        let draft = RecipeImport(recipe: nil, title: "Chili", url: long).draft(householdSize: 4)
        #expect(draft.link == "https://recipes.example/chili")
        _ = try draft.validated()
    }

    @Test func decodesTheFunctionsAnswer() throws {
        let json = #"{"recipe":{"name":"Tacos","servings":4,"ingredients":["1 lb beef"],"steps":[],"imageURL":null},"title":"Tacos","url":"https://r.example/t"}"#
        let decoded = try JSONDecoder().decode(RecipeImport.self, from: Data(json.utf8))
        #expect(decoded.recipe?.name == "Tacos")
        let none = try JSONDecoder().decode(RecipeImport.self, from: Data(#"{"recipe":null,"title":null,"url":"https://r.example/x"}"#.utf8))
        #expect(!none.hasRecipe)
    }
}

@MainActor
struct LinkImportStoreTests {
    @Test func aBareDomainGetsHTTPS() async {
        let sent = Mutex<String?>(nil)
        let store = LibraryStore(householdID: UUID(), client: .fake(importRecipe: { link in
            sent.withLock { $0 = link }
            return RecipeImport(recipe: nil, title: "Hi", url: URL(string: link)!)
        }))
        #expect(await store.importRecipe("  recipes.example/chili ") != nil)
        #expect(sent.withLock { $0 } == "https://recipes.example/chili")
    }

    @Test func refusedAndUnreachableLinksSaySo() async {
        let blocked = LibraryStore(householdID: UUID(), client: .fake(importRecipe: { _ in
            throw RecipeImportError.notAllowed
        }))
        #expect(await blocked.importRecipe("http://10.0.0.1") == nil)
        #expect(blocked.errorMessage?.contains("can't open") == true)

        let down = LibraryStore(householdID: UUID(), client: .fake())
        #expect(await down.importRecipe("https://recipes.example") == nil)
        #expect(down.errorMessage?.contains("Couldn't read") == true)
    }

    @Test func linksAreWebAddresses() {
        #expect(LibraryStore.webLink("recipes.example/chili")?.absoluteString == "https://recipes.example/chili")
        #expect(LibraryStore.webLink("http://r.example")?.absoluteString == "http://r.example")
        #expect(LibraryStore.webLink("chili with beans") == nil)
        #expect(LibraryStore.webLink("ftp://r.example/file") == nil)
        #expect(LibraryStore.webLink("tacos") == nil)
    }

    @Test func notALinkNeverCallsTheServer() async {
        let store = LibraryStore(householdID: UUID(), client: .fake(importRecipe: { _ in
            Issue.record("not called")
            throw RecipeImportError.unavailable
        }))
        #expect(await store.importRecipe("chili with beans") == nil)
        #expect(store.errorMessage != nil)
    }
}
