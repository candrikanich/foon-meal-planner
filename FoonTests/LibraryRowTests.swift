import Testing
@testable import Foon

struct LibraryRowTests {
    @Test func countAgreesWithOneMeal() {
        #expect(LibraryText.count(1) == "1 meal")
        #expect(LibraryText.count(4) == "4 meals")
    }

    @Test func theFiltersPillNamesTheActiveFilter() {
        #expect(LibraryText.filtersPill([]) == "Filters")
        #expect(LibraryText.filtersPill([.favorites]) == "Filters · Favorites")
        #expect(LibraryText.filtersPill([.quick, .favorites]) == "Filters · 2", "past one, a count")
    }

    @Test func voiceOverNamesEveryChosenFilterInChipOrder() {
        #expect(LibraryText.filtersLabel([]) == "Filters")
        #expect(LibraryText.filtersLabel([.quick, .favorites]) == "Filters, Favorites and Quick selected")
    }

    @Test func theSummaryAndEmptyStateSayEveryFilterMustMatch() {
        #expect(LibraryText.filtersSummary([.backup]) == "Showing backup dinners")
        #expect(LibraryText.filtersSummary([.quick, .favorites]) == "Showing meals that match all 2 filters")
        let empty = LibraryText.emptyState(filters: [.quick, .backup], searching: false)
        #expect(empty.title == "Nothing matches all of these")
        #expect(LibraryText.emptyState(filters: [.quick], searching: false).title == "No quick meals")
    }

    @Test func theMetaLineListsStatusThenTags() {
        var meal = LibraryMeal.fixture(name: "Chili")
        #expect(LibraryText.meta(of: meal) == nil)
        meal.tags = [.slowCooker, .quick]
        meal.status = .trial
        #expect(LibraryText.meta(of: meal) == "Trying · Quick · Slow cooker")
    }
}
