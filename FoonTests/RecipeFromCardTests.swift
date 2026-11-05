import Foundation
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let chili = LibraryMeal.fixture(name: "Chili")

private func night(_ offset: Int, mealID: UUID? = nil, pick: QuickPick? = nil, leftoversFrom: UUID? = nil,
                   stashItemID: UUID? = nil) -> WeekNight {
    WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: "18:00", mealID: mealID,
              mealName: mealID == nil ? nil : "Chili", quickPick: pick, locked: false, attendance: [:],
              leftoversFrom: leftoversFrom, stashItemID: stashItemID)
}

@MainActor private func card(_ night: WeekNight, nights: [WeekNight]? = nil, library: [LibraryMeal] = [chili],
                  isAway: Bool = false) -> DayCardModel {
    WeekStore.planCard(for: night, nights: nights ?? [night], members: [], library: library, allergies: [],
                       settings: HouseholdSettings(), today: sunday, minuteNow: 0, isAway: isAway, lookup: .loaded)
}

/// Whoever's cooking opens the night's recipe from its card (#267).
@MainActor struct RecipeFromCardTests {
    @Test func aPlannedDishOpensItsRecipe() {
        #expect(card(night(0, mealID: chili.id)).recipeMealID == chili.id)
    }

    @Test func anAwayNightHasNothingToOpen() {
        #expect(card(night(0, mealID: chili.id), isAway: true).recipeMealID == nil)
    }

    @Test func aDishGoneFromTheLibraryIsntADeadEnd() {
        #expect(card(night(0, mealID: chili.id), library: []).recipeMealID == nil)
    }

    @Test func aNightWithNothingToCookHasNoRecipe() {
        #expect(card(night(0)).recipeMealID == nil)
        #expect(card(night(0, pick: .takeout)).recipeMealID == nil)
    }

    @Test func leftoversAndTheFreezerAreAlreadyCooked() {
        let monday = night(1, mealID: chili.id)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        #expect(card(tuesday, nights: [monday, tuesday]).recipeMealID == nil)
        #expect(card(night(3, mealID: chili.id, stashItemID: UUID())).recipeMealID == nil)
    }
}
