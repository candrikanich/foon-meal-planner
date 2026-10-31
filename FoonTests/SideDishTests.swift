import Foundation
import Synchronization
import Testing
@testable import Foon

struct SideDishDraftTests {
    private let spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti", "pasta sauce"])
    private let caesar = LibraryMeal.fixture(name: "Caesar salad", ingredients: ["romaine", "croutons"])

    @Test func aSideNamedLikeALibraryMealIsThatMeal() {
        var draft = MealDraft(spaghetti)
        draft.addSide("  caesar SALAD ", library: [spaghetti, caesar])
        #expect(draft.sides == [.meal(caesar.id)])
    }

    @Test func anyOtherSideIsASimpleItem() {
        var draft = MealDraft(spaghetti)
        draft.addSide("Garlic bread", library: [spaghetti, caesar])
        #expect(draft.sides == [.item("Garlic bread")])
    }

    @Test func aMealIsNotItsOwnSideAndRepeatsAreIgnored() {
        var draft = MealDraft(spaghetti)
        draft.addSide("Spaghetti", library: [spaghetti, caesar])
        #expect(draft.sides == [.item("Spaghetti")], "its own name is just an item, never the meal itself")
        draft.addSide("garlic bread", library: [spaghetti])
        draft.addSide("Garlic Bread", library: [spaghetti])
        draft.addSide("   ", library: [spaghetti])
        #expect(draft.sides == [.item("Spaghetti"), .item("garlic bread")])
    }

    @Test func aRetiredMealIsNeverLinkedAsASide() {
        let liver = LibraryMeal.fixture(name: "Liver and onions", status: .retired)
        let ziti = LibraryMeal.fixture(name: "Baked ziti", status: .archived)
        var draft = MealDraft(spaghetti)
        draft.addSide("Liver and onions", library: [spaghetti, liver, ziti])
        draft.addSide("Baked ziti", library: [spaghetti, liver, ziti])
        #expect(draft.sides == [.item("Liver and onions"), .meal(ziti.id)], "archived is fine as a side; retired is not")
    }

    @Test func sidesStartFromTheMealAndAreSaved() throws {
        var meal = spaghetti
        meal.sides = [.meal(caesar.id), .item(itemID: UUID(), name: "garlic bread")]
        let saved = try MealDraft(meal).validated()
        #expect(saved.sides == [.meal(caesar.id), .item("garlic bread")])
    }

    @Test func sideNamesMustFit() {
        var draft = MealDraft(spaghetti)
        draft.sides = [.item(String(repeating: "x", count: 61))]
        #expect(throws: MealDraft.Problem.ingredientTooLong) { try draft.validated() }
    }

    @Test func sidesEncodeAsMealIDsOrNames() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000002a2")!
        let json = String(decoding: try JSONEncoder().encode([MealDraft.Saved.Side.meal(id), .item("salad")]),
                          as: UTF8.self)
        #expect(json == #"[{"meal_id":"00000000-0000-0000-0000-0000000002A2"},{"name":"salad"}]"#)
    }
}

struct ShoppingLinesTests {
    private let caesar = LibraryMeal.fixture(name: "Caesar salad", ingredients: ["romaine", "croutons"])

    @Test func aMealsLinesIncludeItsSides() {
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti", "pasta sauce"])
        let bread = UUID()
        spaghetti.sides = [.meal(caesar.id), .item(itemID: bread, name: "garlic bread")]
        let lines = ShoppingLines.lines(for: spaghetti, library: [spaghetti, caesar])
        #expect(lines.map(\.name) == ["spaghetti", "pasta sauce", "romaine", "croutons", "garlic bread"])
        #expect(lines.map(\.forMeal) == ["Spaghetti", "Spaghetti", "Caesar salad", "Caesar salad", "Spaghetti"])
        #expect(lines.last?.itemID == bread)
    }

    @Test func aSidesOwnSidesAreNotFollowed() {
        var caesar = caesar
        caesar.sides = [.item(itemID: UUID(), name: "breadsticks")]
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti"])
        spaghetti.sides = [.meal(caesar.id)]
        #expect(ShoppingLines.lines(for: spaghetti, library: [spaghetti, caesar]).map(\.name)
            == ["spaghetti", "romaine", "croutons"])
    }

    @Test func aSideRetiredAfterItWasLinkedIsSkipped() {
        let liver = LibraryMeal.fixture(name: "Liver and onions", status: .retired, ingredients: ["liver"])
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti"])
        spaghetti.sides = [.meal(liver.id)]
        #expect(ShoppingLines.lines(for: spaghetti, library: [spaghetti, liver]).map(\.name) == ["spaghetti"])
    }

    @Test func aSideThatIsNoLongerInTheLibraryIsSkipped() {
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti"])
        spaghetti.sides = [.meal(UUID())]
        #expect(ShoppingLines.lines(for: spaghetti, library: [spaghetti]).map(\.name) == ["spaghetti"])
    }

    @Test func quantitiesCarryThrough() {
        let tacos = LibraryMeal(
            id: UUID(), householdID: Household.sample.id, catalogMealID: nil, name: "Tacos", servings: 4, tags: [],
            status: .active, photoPath: nil, madeByMemberID: nil, createdAt: .now,
            ingredients: [MealIngredient(itemID: UUID(), name: "ground beef", quantityText: "1 lb", position: 1)],
            steps: [], sourceURL: nil, prepSteps: []
        )
        #expect(ShoppingLines.lines(for: tacos, library: [tacos]).first?.quantity == "1 lb")
    }
}

struct SideDishTextTests {
    @Test(arguments: [
        ([String](), nil as String?),
        (["salad"], "with salad"),
        (["salad", "garlic bread"], "with salad and garlic bread"),
        (["salad", "garlic bread", "corn"], "with salad, garlic bread, and corn")
    ])
    func sidesReadAsAPhrase(sides: [String], text: String?) {
        #expect(DayCardText.sidesLabel(sides, locale: Locale(identifier: "en_US")) == text)
    }

    @Test func theCardSummaryMentionsSides() {
        let calendar = Calendar(identifier: .gregorian)
        let today = CalendarDay(year: 2026, month: 11, day: 4)
        let card = DayCardModel(date: today, effort: .normal,
                                slot: .meal(name: "Spaghetti", photoURL: nil, reason: nil, sides: ["salad"]),
                                attendance: [], badges: [], isLocked: false)
        #expect(DayCardText.accessibilitySummary(card, today: today, calendar: calendar)
            .hasPrefix("Tonight, Nov 4. Spaghetti, with salad. Normal."))
    }
}

struct SideDishAllergyTests {
    /// What's served is what's flagged: a side's ingredients count, so library, cards, and the list agree.
    @Test func aSideWithMilkFlagsTheMainMeal() {
        let nora = MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])
        let caesar = LibraryMeal.fixture(name: "Caesar salad", ingredients: ["romaine", "parmesan"])
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti"])
        spaghetti.sides = [.meal(caesar.id), .item(itemID: UUID(), name: "peanut noodles")]
        let peanuts = MemberAllergies(memberID: UUID(), firstName: "Owen", allergens: [.peanuts])
        let entry = LibraryQuery.entries(allOf: [spaghetti, caesar], history: [], allergies: [nora, peanuts],
                                         favorites: [])[0]
        #expect(entry.flags.map(\.summary) == ["Contains milk (Nora)", "Contains peanuts (Owen)"])
    }
}

@MainActor
struct SideDishStoreTests {
    @Test func sideNamesComeFromTheLibraryAndItems() async {
        let caesar = LibraryMeal.fixture(name: "Caesar salad")
        var spaghetti = LibraryMeal.fixture(name: "Spaghetti")
        let liver = LibraryMeal.fixture(name: "Liver and onions", status: .retired)
        spaghetti.sides = [.meal(caesar.id), .item(itemID: UUID(), name: "garlic bread"), .meal(UUID()), .meal(liver.id)]
        let meals = [spaghetti, caesar, liver]
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in meals }))
        await store.load(members: [])
        #expect(store.sideNames(for: spaghetti) == ["Caesar salad", "garlic bread"])
    }
}
