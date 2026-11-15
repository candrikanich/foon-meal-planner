import Testing
@testable import Foon

struct LibraryRowTests {
    @Test func countAgreesWithOneMeal() {
        #expect(LibraryText.count(1) == "1 meal")
        #expect(LibraryText.count(4) == "4 meals")
    }

    @Test func theFiltersPillNamesTheActiveFilter() {
        #expect(LibraryText.filtersPill(nil) == "Filters")
        #expect(LibraryText.filtersPill(.favorites) == "Filters · Favorites")
    }

    @Test func theMetaLineListsStatusThenTags() {
        var meal = LibraryMeal.fixture(name: "Chili")
        #expect(LibraryText.meta(of: meal) == nil)
        meal.tags = [.slowCooker, .quick]
        meal.status = .trial
        #expect(LibraryText.meta(of: meal) == "Trying · Quick · Slow cooker")
    }
}
