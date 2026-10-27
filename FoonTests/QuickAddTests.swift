import Foundation
import Synchronization
import Testing
@testable import Foon

/// Autocomplete while typing several ingredients in one field (#20).
struct IngredientTypingTests {
    private let items = ["ground beef", "taco shells", "shredded cheese", "sour cream"]

    @Test(arguments: [
        ("1 lb ground beef, ta", "ta"),
        ("1 lb ground beef,\n2 cups shre", "shre"),
        ("sour", "sour"),
        ("1 lb ground beef, ", ""),
        ("", "")
    ])
    func theIngredientBeingTypedIsTheLastOne(text: String, typing: String) {
        #expect(IngredientAutocomplete.typing(in: text) == typing)
    }

    @Test func separatorsInsideParenthesesDoNotStartANewIngredient() {
        #expect(IngredientAutocomplete.typing(in: "1 (14.5 oz, dic") == "", "still inside the size note")
        #expect(IngredientAutocomplete.suggestions(whileTyping: "1 (14.5 oz, dic", from: ["diced tomatoes"]).isEmpty)
        #expect(IngredientAutocomplete.typing(in: "1 (14.5 oz) can diced tomatoes, sou") == "sou")
    }

    @Test func aBulletSeparatesIngredientsToo() {
        #expect(IngredientAutocomplete.typing(in: "beef • shre") == "shre")
        #expect(IngredientAutocomplete.completing("beef • shre", with: "shredded cheese") == "beef • shredded cheese, ")
    }

    @Test func aUnitWordAloneIsTheStartOfAName() {
        #expect(IngredientAutocomplete.typing(in: "can") == "can")
        #expect(IngredientAutocomplete.typing(in: "1 can") == "")
    }

    @Test func aQuantityIsNotPartOfWhatIsBeingTyped() {
        #expect(IngredientAutocomplete.typing(in: "1 lb ground beef, 2 cups shre") == "shre")
        #expect(IngredientAutocomplete.typing(in: "2 cups") == "")
    }

    @Test func suggestionsFollowTheLastIngredient() {
        #expect(IngredientAutocomplete.suggestions(whileTyping: "1 lb ground beef, ta", from: items) == ["taco shells"])
        #expect(IngredientAutocomplete.suggestions(whileTyping: "1 lb ground beef, ", from: items).isEmpty)
    }

    @Test func anExactMatchNeedsNoSuggestion() {
        #expect(IngredientAutocomplete.suggestions(whileTyping: "taco shells", from: items).isEmpty)
    }

    @Test func choosingASuggestionCompletesTheLastIngredientAndKeepsItsQuantity() {
        #expect(IngredientAutocomplete.completing("1 lb ground beef, 2 cups shre", with: "shredded cheese")
            == "1 lb ground beef, 2 cups shredded cheese, ")
        #expect(IngredientAutocomplete.completing("ta", with: "taco shells") == "taco shells, ")
        #expect(IngredientAutocomplete.completing("beef\nsour", with: "sour cream") == "beef\nsour cream, ")
    }
}

struct QuickAddDraftTests {
    @Test func aNewMealStartsWithSensibleDefaults() throws {
        let saved = try MealDraft(newNamed: " Taco night ").validated()
        #expect(saved.name == "Taco night")
        #expect(saved.servings == 4)
        #expect(saved.lines.isEmpty)
        #expect(saved.tags.isEmpty)
    }

    @Test func tilesWithoutIngredientsSaySo() {
        let entry = LibraryEntry(meal: .fixture(name: "Soup"), history: nil, flags: [], isFavorite: false)
        #expect(LibraryText.accessibilityLabel(entry, madeBy: nil) == "Soup, Add ingredients")
        let full = LibraryEntry(meal: .fixture(name: "Tacos", ingredients: ["beef"]), history: nil, flags: [],
                                isFavorite: false)
        #expect(LibraryText.accessibilityLabel(full, madeBy: nil) == "Tacos")
    }
}

@MainActor
struct QuickAddStoreTests {
    private let household = Household.sample.id

    @Test func quickAddSendsTheNameAndParsedIngredientsThenReloads() async {
        let created = Mutex<MealDraft.Saved?>(nil)
        let newID = UUID()
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in created.withLock { $0 }.map { [LibraryMeal.fixture(id: newID, name: $0.name)] } ?? [] },
            create: { householdID, meal in
                #expect(householdID == household)
                created.withLock { $0 = meal }
                return newID
            }
        ))
        await store.load(members: [])
        #expect(await store.quickAdd(name: "Taco night", ingredients: "1 lb ground beef, taco shells") == newID)
        let sent = created.withLock { $0 }
        #expect(sent?.name == "Taco night")
        #expect(sent?.lines == [.init(name: "ground beef", quantity: "1 lb"), .init(name: "taco shells", quantity: nil)])
        #expect(store.meal(newID)?.name == "Taco night")
    }

    @Test func aBlankNameNeverReachesTheServer() async {
        let store = LibraryStore(householdID: household, client: .fake(create: { _, _ in
            Issue.record("should not be called")
            return UUID()
        }))
        #expect(await store.quickAdd(name: "  ", ingredients: "") == nil)
        #expect(store.errorMessage == MealDraft.Problem.nameMissing.message)
    }

    @Test func autocompleteUsesEveryHouseholdItem() async {
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [.fixture(name: "Tacos", ingredients: ["ground beef"])] },
            itemNames: { _ in ["paper towels", "ground beef", "milk"] }
        ))
        await store.load(members: [])
        #expect(store.ingredientNames.sorted() == ["ground beef", "milk", "paper towels"])
    }
}
