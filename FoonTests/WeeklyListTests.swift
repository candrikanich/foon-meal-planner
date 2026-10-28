import Foundation
import Synchronization
import Testing
@testable import Foon

struct WeeklyListTests {
    private let nora = UUID(), owen = UUID()
    private let beef = UUID(), shells = UUID(), cheese = UUID(), milk = UUID(), pasta = UUID(), bread = UUID()

    private let tacos: LibraryMeal
    private let mac: LibraryMeal

    init() {
        tacos = Self.meal("Tacos", [(beef, "ground beef", "1 lb"), (shells, "taco shells", nil),
                                    (cheese, "cheddar cheese", "1 cup")])
        mac = Self.meal("Mac and cheese", [(pasta, "elbow macaroni", "1 box"), (cheese, "cheddar cheese", "2 cups"),
                                           (milk, "milk", nil)])
    }

    private static func meal(_ name: String, _ lines: [(UUID, String, String?)], sides: [MealSide] = []) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: name)
        meal.ingredients = lines.enumerated().map { index, line in
            MealIngredient(itemID: line.0, name: line.1, quantityText: line.2, position: index + 1)
        }
        meal.sides = sides
        return meal
    }

    private func meal(_ name: String, _ lines: [(UUID, String, String?)], sides: [MealSide] = []) -> LibraryMeal {
        Self.meal(name, lines, sides: sides)
    }

    private func night(_ meal: LibraryMeal?, home: [UUID] = []) -> WeeklyList.Night {
        WeeklyList.Night(mealID: meal?.id, home: Set(home))
    }

    @Test func mergesIngredientsAcrossMealsByItem() {
        let lines = WeeklyList.build(nights: [night(tacos), night(mac)], library: [tacos, mac])
        #expect(lines.map(\.name) == ["ground beef", "taco shells", "cheddar cheese", "elbow macaroni", "milk"])
        let cheddar = lines.first { $0.itemID == cheese }
        #expect(cheddar?.quantity == "1 cup + 2 cups")
        #expect(cheddar?.forMeals == ["Tacos", "Mac and cheese"])
    }

    @Test func theSameMealTwiceCountsItsQuantitiesTwice() {
        let lines = WeeklyList.build(nights: [night(tacos), night(tacos)], library: [tacos])
        #expect(lines.first { $0.itemID == beef }?.quantity == "1 lb + 1 lb")
        #expect(lines.first { $0.itemID == beef }?.forMeals == ["Tacos"])
    }

    @Test func sidesComeAlong() {
        let salad = meal("Caesar salad", [(UUID(), "romaine", nil)])
        let spaghetti = meal("Spaghetti", [(pasta, "spaghetti", nil)], sides: [.meal(salad.id), .item(itemID: bread, name: "garlic bread")])
        let lines = WeeklyList.build(nights: [night(spaghetti)], library: [spaghetti, salad])
        #expect(lines.map(\.name) == ["spaghetti", "romaine", "garlic bread"])
    }

    @Test func itemsInStockAreLeftOffButLowOnesStay() {
        let lines = WeeklyList.build(nights: [night(mac)], library: [mac],
                                     stock: [milk: .in, pasta: .low])
        #expect(!lines.contains { $0.itemID == milk })
        #expect(lines.contains { $0.itemID == pasta })
    }

    @Test func lowAndOutStaplesAreAddedOnce() {
        let cereal = UUID(), towels = UUID()
        let staples = [WeeklyList.Staple(itemID: cereal, name: "cereal", state: .out),
                       WeeklyList.Staple(itemID: towels, name: "paper towels", state: .low),
                       WeeklyList.Staple(itemID: milk, name: "milk", state: .out),
                       WeeklyList.Staple(itemID: UUID(), name: "rice", state: .in)]
        let lines = WeeklyList.build(nights: [night(mac)], library: [mac], staples: staples)
        #expect(lines.suffix(2).map(\.name) == ["cereal", "paper towels"])
        #expect(lines.suffix(2).allSatisfy { $0.isStaple })
        #expect(lines.filter { $0.itemID == milk }.count == 1, "milk from the meal and the staple show once")
    }

    @Test func allergyNotesNameWhoIsHomeWhenItsServed() {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk]),
                         MemberAllergies(memberID: owen, firstName: "Owen", allergens: [.wheat])]
        let lines = WeeklyList.build(nights: [night(mac, home: [nora])], library: [mac], allergies: allergies)
        #expect(lines.first { $0.itemID == cheese }?.note == "Get dairy-free (Nora)")
        #expect(lines.first { $0.itemID == milk }?.note == "Get dairy-free (Nora)")
        #expect(lines.first { $0.itemID == pasta }?.note == nil, "Owen isn't home that night")
    }

    @Test func notesForSeveralAllergensAndPeopleRead() {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk, .wheat]),
                         MemberAllergies(memberID: owen, firstName: "Owen", allergens: [.milk])]
        let pizza = meal("Pizza", [(UUID(), "pizza dough", nil), (cheese, "mozzarella cheese", nil)])
        let lines = WeeklyList.build(nights: [night(pizza, home: [nora, owen])], library: [pizza], allergies: allergies)
        #expect(lines.first { $0.itemID == cheese }?.note == "Get dairy-free (Nora, Owen)")
        #expect(lines.first { $0.name == "pizza dough" }?.note == "Get gluten-free (Nora)")
    }

    @Test(arguments: [(Allergen.eggs, "Get egg-free"), (.peanuts, "Get peanut-free"), (.treeNuts, "Get nut-free"),
                      (.soy, "Get soy-free"), (.sesame, "Get sesame-free"), (.fish, "Skip fish"),
                      (.shellfish, "Skip shellfish")])
    func eachAllergenHasAShoppingNote(allergen: Allergen, note: String) {
        #expect(WeeklyList.shoppingAdvice(allergen) == note)
    }

    @Test func customAllergiesAskToCheck() {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", customTexts: ["kiwi"])]
        let fruit = meal("Fruit salad", [(UUID(), "kiwi", nil)])
        let lines = WeeklyList.build(nights: [night(fruit, home: [nora])], library: [fruit], allergies: allergies)
        #expect(lines.first?.note == "Check for kiwi (Nora)")
    }

    @Test func manyLongAllergyNotesAreShortenedNeverDropped() {
        let texts = ["strawberries and other red berries", "kiwi fruit of any kind at all", "mango and papaya fruit",
                     "pineapple chunks or juice"]
        let people = (0..<4).map { index in
            MemberAllergies(memberID: UUID(), firstName: ["Alexandra", "Benjamin", "Christopher", "Dominique"][index],
                            allergens: [.milk], customTexts: [texts[index]])
        }
        let smoothie = meal("Smoothie", [(UUID(), "milk with strawberries and other red berries kiwi fruit of any kind at all mango and papaya fruit pineapple chunks or juice", nil)])
        let lines = WeeklyList.build(nights: [night(smoothie, home: people.map(\.memberID))], library: [smoothie],
                                     allergies: people)
        let note = lines.first?.note ?? ""
        #expect(note.unicodeScalars.count <= 140)
        #expect(note.contains("dairy-free") || note.contains("milk"))
        for text in texts { #expect(note.contains(String(text.prefix(12))), "\(text) is still named") }
    }

    @Test func quickPickAndEmptyNightsAddNothing() {
        #expect(WeeklyList.build(nights: [night(nil), night(nil)], library: [tacos]).isEmpty)
    }

    @Test func quantitiesStayShortEnoughToSave() {
        let lines = WeeklyList.build(nights: Array(repeating: night(tacos), count: 7), library: [tacos])
        #expect((lines.first?.quantity?.unicodeScalars.count ?? 0) <= 60)
    }
}

@MainActor
struct ApproveTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    @Test func approvingSendsTheListAndStampsTheWeek() async {
        let sent = Mutex<[WeeklyList.Line]>([])
        let existing = Week(planID: UUID(), start: sunday, approvedAt: nil, nights: [])
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            approve: { _, lines in sent.withLock { $0 = lines } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let lines = [WeeklyList.Line(itemID: UUID(), name: "milk", quantity: nil, forMeals: ["Mac"], note: nil, isStaple: false)]
        #expect(await store.approve(lines))
        #expect(sent.withLock { $0 } == lines)
        #expect(store.week?.approvedAt != nil)
    }

    @Test func approvingWhileTheWeekSwitchesDoesNotStampTheOtherWeek() async {
        let gate = AsyncStream<Void>.makeStream()
        let thisWeek = Week(planID: UUID(), start: sunday, approvedAt: nil, nights: [])
        let nextWeek = Week(planID: UUID(), start: sunday.adding(days: 7), approvedAt: nil, nights: [])
        let approving = Mutex(false)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, start in start == sunday ? thisWeek : nextWeek },
            approve: { _, _ in
                approving.withLock { $0 = true }
                for await _ in gate.stream { break }
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        async let approval = store.approve([])
        while !approving.withLock({ $0 }) { await Task.yield() }
        store.showingNextWeek = true
        await store.load(settings: HouseholdSettings())
        gate.continuation.yield()
        _ = await approval
        #expect(store.week?.planID == nextWeek.planID)
        #expect(store.week?.approvedAt == nil)
    }

    @Test func aFailedApprovalSaysSo() async {
        let existing = Week(planID: UUID(), start: sunday, approvedAt: nil, nights: [])
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, approve: { _, _ in throw URLError(.notConnectedToInternet) }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(!(await store.approve([])))
        #expect(store.week?.approvedAt == nil)
        #expect(store.errorMessage != nil)
    }
}
