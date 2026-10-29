import Foundation
import Synchronization
import Testing
@testable import Foon

struct ReactionSummaryTests {
    private let ann = UUID(), nora = UUID(), owen = UUID()
    private let chili = UUID(), liver = UUID(), tacos = UUID()
    private let today = CalendarDay(year: 2026, month: 11, day: 20)

    private func verdict(_ meal: UUID, _ member: UUID, _ kind: ReactionKind, daysAgo: Int = 1) -> MealVerdict {
        MealVerdict(mealID: meal, memberID: member, kind: kind, reactedOn: today.adding(days: -daysAgo))
    }

    @Test func oneDislikeSkipsTheirNightsTwoRetire() {
        let summary = ReactionSummary(verdicts: [verdict(chili, nora, .notForMe), verdict(liver, nora, .notForMe),
                                                 verdict(liver, owen, .notForMe)])
        #expect(summary.notForMe[chili] == [nora: 1])
        #expect(summary.notForMe[liver] == [nora: 1, owen: 1])
    }

    @Test func favoritesArePinnedToThePerson() {
        let summary = ReactionSummary(verdicts: [verdict(tacos, ann, .favorite), verdict(tacos, nora, .favorite),
                                                 verdict(chili, ann, .good)])
        #expect(summary.favorites == [ann: [tacos], nora: [tacos]])
        #expect(summary.favoriteCount(tacos) == 2)
        #expect(summary.favoriteCount(chili) == 0)
    }

    @Test func tiredOfItSnoozesForAFewWeeks() {
        let recent = ReactionSummary(verdicts: [verdict(chili, ann, .tiredOfIt, daysAgo: 20)])
        let old = ReactionSummary(verdicts: [verdict(chili, ann, .tiredOfIt, daysAgo: 21)])
        #expect(recent.snoozed(today: today) == [chili])
        #expect(old.snoozed(today: today).isEmpty, "three weeks later it's back in rotation")
    }

    @Test func likesAddUp() {
        let summary = ReactionSummary(likes: [MealLikes(mealID: chili, likes: 3)])
        #expect(summary.likes == [chili: 3])
    }

    @Test func verdictsDecodeFromTheView() throws {
        let json = #"[{"meal_id":"\#(chili)","member_id":"\#(ann)","reaction":"tired_of_it","reacted_on":"2026-11-19"}]"#
        let verdicts = try JSONDecoder().decode([MealVerdict].self, from: Data(json.utf8))
        #expect(verdicts == [verdict(chili, ann, .tiredOfIt)])
    }

    @Test func planningGetsTheDislikesSnoozesAndFavorites() {
        let meals = [LibraryMeal.fixture(name: "Chili"), LibraryMeal.fixture(name: "Liver")]
        let summary = ReactionSummary(verdicts: [
            verdict(meals[0].id, ann, .favorite), verdict(meals[1].id, nora, .notForMe),
            verdict(meals[1].id, owen, .notForMe), verdict(meals[0].id, nora, .tiredOfIt, daysAgo: 3)
        ], likes: [MealLikes(mealID: meals[0].id, likes: 2)])
        let week = Week(planID: UUID(), start: today, approvedAt: nil, nights: [])
        let inputs = PlanningContext(meals: meals, history: [], settings: HouseholdSettings(), members: [],
                                     reactions: summary).inputs(for: week, today: today)
        #expect(Set(inputs.meals.map(\.name)) == ["Chili", "Liver"],
                "the meal's status decides: a planner may have brought the liver back")
        #expect(inputs.favorites == [ann: [meals[0].id]])
        #expect(inputs.likes == [meals[0].id: 2])
        #expect(inputs.notForMe[meals[1].id]?.count == 2)
        #expect(inputs.snoozedMealIDs == [meals[0].id], "Nora's tired of the chili for now")
    }
}

@MainActor
struct LibraryFavoritesTests {
    @Test func favoritesComeFromVerdictsAndSortTheFamilyFavoritesFirst() async {
        let chili = LibraryMeal.fixture(name: "Chili"), tacos = LibraryMeal.fixture(name: "Tacos"),
            soup = LibraryMeal.fixture(name: "Soup")
        let ann = UUID(), nora = UUID()
        let day = CalendarDay(year: 2026, month: 11, day: 1)
        let store = LibraryStore(householdID: UUID(), client: .fake(
            meals: { _ in [chili, tacos, soup] }
        ).with(
            verdicts: [MealVerdict(mealID: tacos.id, memberID: ann, kind: .favorite, reactedOn: day),
                       MealVerdict(mealID: tacos.id, memberID: nora, kind: .favorite, reactedOn: day),
                       MealVerdict(mealID: soup.id, memberID: ann, kind: .favorite, reactedOn: day)],
            likes: [MealLikes(mealID: chili.id, likes: 5)]
        ))
        await store.load(members: [])
        store.filter = .favorites
        #expect(store.visibleEntries.map(\.meal.name) == ["Soup", "Tacos"], "the Favorites chip isn't empty anymore")
        store.filter = nil
        store.sort = .familyFavorites
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos", "Soup", "Chili"],
                "two favorites, then one, then liked but nobody's favorite")
    }
}

@MainActor
struct RefreshReactionsTests {
    @Test func doesNothingBeforeTheLibraryLoadsAndKeepsWhatItHadOffline() async {
        let calls = Mutex(0)
        let offline = Mutex(false)
        let day = CalendarDay(year: 2026, month: 11, day: 1)
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.verdicts = { _ in
            calls.withLock { $0 += 1 }
            if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return [MealVerdict(mealID: tacos.id, memberID: UUID(), kind: .favorite, reactedOn: day)]
        }
        let store = LibraryStore(householdID: UUID(), client: client)
        await store.refreshReactions()
        #expect(calls.withLock { $0 } == 0, "nothing to refresh before the first load")
        await store.load(members: [])
        offline.withLock { $0 = true }
        await store.refreshReactions()
        #expect(store.reactions.favoriteCount(tacos.id) == 1, "offline: the last answers still stand")
    }
}

private extension LibraryClient {
    func with(verdicts: [MealVerdict], likes: [MealLikes]) -> LibraryClient {
        var client = self
        client.verdicts = { _ in verdicts }
        client.likes = { _ in likes }
        return client
    }
}
