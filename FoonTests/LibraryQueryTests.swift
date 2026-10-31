import Foundation
import Testing
@testable import Foon

extension LibraryQuery {
    /// Tests that show the whole library, so what's shown and where sides are found are the same list.
    static func entries(allOf meals: [LibraryMeal], history: [MealHistory], allergies: [MemberAllergies],
                        favorites: Set<UUID>, favoriteCounts: [UUID: Int] = [:], likes: [UUID: Int] = [:]) -> [LibraryEntry] {
        entries(meals: meals, library: meals, history: history, allergies: allergies, favorites: favorites,
                favoriteCounts: favoriteCounts, likes: likes)
    }
}

struct LibraryQueryTests {
    private let nora = MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])

    private func meal(
        _ name: String,
        tags: [MealTag] = [],
        status: MealStatus = .active,
        ingredients: [String] = [],
        addedDaysAgo: Int = 0,
        catalogMealID: UUID? = nil
    ) -> LibraryMeal {
        .fixture(name: name, tags: tags, status: status, ingredients: ingredients,
                 createdAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(addedDaysAgo) * 86_400),
                 catalogMealID: catalogMealID)
    }

    private func names(_ entries: [LibraryEntry]) -> [String] { entries.map(\.meal.name) }

    // MARK: Entries

    @Test func entriesCarryHistoryFlagsAndFavorites() {
        let mac = meal("Mac and cheese", ingredients: ["elbow macaroni", "cheddar cheese"])
        let history = MealHistory(mealID: mac.id, timesMade: 3, lastMade: CalendarDay(year: 2026, month: 10, day: 1))
        let entry = LibraryQuery.entries(allOf: [mac], history: [history], allergies: [nora], favorites: [mac.id])[0]
        #expect(entry.history == history)
        #expect(entry.flags.map(\.summary) == ["Contains milk (Nora)"])
        #expect(entry.isFavorite)
    }

    // MARK: Filters

    @Test func theDefaultViewHidesArchivedAndRetiredMeals() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Tacos"), meal("Trial curry", status: .trial),
            meal("Old casserole", status: .archived), meal("Liver", status: .retired)
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .recentlyAdded, search: ""))
            == ["Tacos", "Trial curry"])
    }

    @Test func archivedShowsArchivedAndRetiredMeals() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Tacos"), meal("Old casserole", status: .archived, addedDaysAgo: 1),
            meal("Liver", status: .retired, addedDaysAgo: 2)
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: .archived, sort: .recentlyAdded, search: ""))
            == ["Old casserole", "Liver"])
    }

    @Test(arguments: [
        (LibraryFilter.quick, ["Tacos"]),
        (.trying, ["Trial curry"]),
        (.backup, ["Frozen pizza"]),
        (.favorites, ["Lasagna"]),
        (.allergyFlags, ["Lasagna"])
    ])
    func filtersNarrowTheLibrary(filter: LibraryFilter, expected: [String]) {
        let lasagna = meal("Lasagna", ingredients: ["ricotta", "lasagna noodles"], addedDaysAgo: 3)
        let entries = LibraryQuery.entries(allOf: [
            meal("Tacos", tags: [.quick, .beginner]),
            meal("Trial curry", status: .trial, addedDaysAgo: 1),
            meal("Frozen pizza", tags: [.backup], addedDaysAgo: 2),
            lasagna,
            meal("Archived quick thing", tags: [.quick, .backup], status: .archived, addedDaysAgo: 4)
        ], history: [], allergies: [nora], favorites: [lasagna.id])
        #expect(names(LibraryQuery.apply(entries, filter: filter, sort: .recentlyAdded, search: "")) == expected)
    }

    // MARK: Sorts

    @Test func haventHadInAWhileShowsTheLongestAgoFirstAndNeverMadeLast() {
        let tacos = meal("Tacos"), chili = meal("Chili"), soup = meal("Soup"), new = meal("New dish")
        let history = [
            MealHistory(mealID: tacos.id, timesMade: 9, lastMade: CalendarDay(year: 2026, month: 10, day: 20)),
            MealHistory(mealID: chili.id, timesMade: 1, lastMade: CalendarDay(year: 2026, month: 3, day: 2)),
            MealHistory(mealID: soup.id, timesMade: 4, lastMade: CalendarDay(year: 2026, month: 8, day: 9))
        ]
        let entries = LibraryQuery.entries(allOf: [tacos, new, chili, soup], history: history, allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .notLately, search: ""))
            == ["Chili", "Soup", "Tacos", "New dish"])
    }

    @Test func mostMadeCountsDownAndBreaksTiesByMostRecent() {
        let tacos = meal("Tacos"), chili = meal("Chili"), soup = meal("Soup"), new = meal("New dish")
        let history = [
            MealHistory(mealID: tacos.id, timesMade: 9, lastMade: CalendarDay(year: 2026, month: 10, day: 20)),
            MealHistory(mealID: chili.id, timesMade: 4, lastMade: CalendarDay(year: 2026, month: 3, day: 2)),
            MealHistory(mealID: soup.id, timesMade: 4, lastMade: CalendarDay(year: 2026, month: 8, day: 9))
        ]
        let entries = LibraryQuery.entries(allOf: [new, chili, soup, tacos], history: history, allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .mostMade, search: ""))
            == ["Tacos", "Soup", "Chili", "New dish"])
    }

    @Test func recentlyAddedIsNewestFirst() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Oldest", addedDaysAgo: 30), meal("Newest", addedDaysAgo: 0), meal("Middle", addedDaysAgo: 5)
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .recentlyAdded, search: ""))
            == ["Newest", "Middle", "Oldest"])
    }

    @Test func tiesFallBackToTheName() {
        let entries = LibraryQuery.entries(allOf: [meal("Ziti"), meal("apple pork"), meal("Burgers")],
                                           history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .notLately, search: ""))
            == ["apple pork", "Burgers", "Ziti"])
    }

    // MARK: Search

    @Test func searchMatchesNamesAndIngredientsIgnoringCaseAndAccents() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Crème brûlée french toast", ingredients: ["bread", "eggs"]),
            meal("Chicken fried rice", ingredients: ["chicken thighs", "rice"]),
            meal("Jambalaya", ingredients: ["andouille sausage", "Rice"])
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .notLately, search: "creme")) == ["Crème brûlée french toast"])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .notLately, search: "RICE"))
            == ["Chicken fried rice", "Jambalaya"])
    }

    @Test func everySearchWordMustMatch() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Chicken fried rice", ingredients: ["chicken thighs", "rice"]),
            meal("Jambalaya", ingredients: ["andouille sausage", "rice"])
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: nil, sort: .notLately, search: " rice  chicken "))
            == ["Chicken fried rice"])
    }

    @Test func searchStaysWithinTheChosenFilter() {
        let entries = LibraryQuery.entries(allOf: [
            meal("Tacos", tags: [.quick]), meal("Fish tacos", status: .archived)
        ], history: [], allergies: [], favorites: [])
        #expect(names(LibraryQuery.apply(entries, filter: .archived, sort: .notLately, search: "tacos")) == ["Fish tacos"])
    }

    // MARK: Catalog

    @Test func catalogMatchesOnlyAppearWhenSearchingAndSkipDishesAlreadyCopied() {
        let tacos = CatalogDish.fixture(name: "Tacos", sortOrder: 2, ingredients: ["ground beef", "taco shells"])
        let fishTacos = CatalogDish.fixture(name: "Fish tacos", sortOrder: 1, ingredients: ["cod"])
        let chili = CatalogDish.fixture(name: "Chili", sortOrder: 3, ingredients: ["ground beef", "beans"])
        let library = [meal("Our tacos", status: .archived, catalogMealID: tacos.id)]
        let catalog = [tacos, fishTacos, chili]
        #expect(LibraryQuery.catalogMatches(catalog, search: "", library: library).isEmpty)
        #expect(LibraryQuery.catalogMatches(catalog, search: "taco", library: library).map(\.name) == ["Fish tacos"])
        #expect(LibraryQuery.catalogMatches(catalog, search: "ground beef", library: library).map(\.name) == ["Chili"])
    }

    /// A dish the dislike rule retired stays retired: re-adding it from the catalog would start its ratings over.
    @Test func aRetiredCopyStillCountsAsInTheLibrary() {
        let tacos = CatalogDish.fixture(name: "Tacos")
        let library = [meal("Tacos", status: .retired, catalogMealID: tacos.id)]
        #expect(LibraryQuery.catalogMatches([tacos], search: "tacos", library: library).isEmpty)
        #expect(LibraryQuery.copiedDishIDs(library) == [tacos.id])
    }

    @Test func browsingGroupsTheCatalogByCategoryInCatalogOrder() {
        let catalog = [
            CatalogDish.fixture(name: "Tacos", category: "Tex-Mex", sortOrder: 8),
            CatalogDish.fixture(name: "Lasagna", category: "Pasta", sortOrder: 5),
            CatalogDish.fixture(name: "Baked ziti", category: "Pasta", sortOrder: 4)
        ]
        let sections = LibraryQuery.catalogSections(catalog)
        #expect(sections.map(\.category) == ["Pasta", "Tex-Mex"])
        #expect(sections[0].dishes.map(\.name) == ["Baked ziti", "Lasagna"])
    }
}
