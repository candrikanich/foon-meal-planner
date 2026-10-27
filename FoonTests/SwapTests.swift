import Foundation
import Synchronization
import Testing
@testable import Foon

struct SwapSuggestionTests {
    private let start = CalendarDay(year: 2026, month: 11, day: 1)
    private let mom = UUID(), nora = UUID()

    private var plain: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.takeoutNights = 0
        return settings
    }

    private func week(rushedOn: Int? = nil) -> [PlanningNight] {
        (0..<7).map { offset in
            PlanningNight(id: UUID(), date: start.adding(days: offset), effort: offset == rushedOn ? .rushed : .normal,
                          attendance: [mom: true, nora: true])
        }
    }

    private func inputs(_ nights: [PlanningNight], meals: [LibraryMeal], settings: HouseholdSettings? = nil,
                        notForMe: [UUID: [UUID: Int]] = [:]) -> PlanningInputs {
        PlanningInputs(nights: nights, meals: meals,
                       history: meals.enumerated().map {
                           MealHistory(mealID: $1.id, timesMade: 3, lastMade: start.adding(days: -20 - $0))
                       },
                       settings: settings ?? plain, memberNames: [mom: "Mom", nora: "Nora"], notForMe: notForMe)
    }

    @Test func threeDistinctSuggestionsWithReasons() {
        let meals = (0..<10).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let nights = week()
        let suggestions = BuildMyWeek.suggestions(night: nights[2].id, inputs: inputs(nights, meals: meals), seed: 7)
        #expect(suggestions.count == 3)
        #expect(Set(suggestions.map(\.mealID)).count == 3)
        #expect(suggestions.allSatisfy { !$0.reason.text.isEmpty })
    }

    @Test func theSameSeedSuggestsTheSameDishes() {
        let meals = (0..<10).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let planning = inputs(week(), meals: meals)
        let night = planning.nights[3].id
        #expect(BuildMyWeek.suggestions(night: night, inputs: planning, seed: 3)
            == BuildMyWeek.suggestions(night: night, inputs: planning, seed: 3))
    }

    @Test func neverSuggestsWhatsAlreadyInTheWeekOrTonightsOwnDish() {
        let meals = (0..<5).map { LibraryMeal.fixture(name: "Dish \($0)") }
        var nights = week()
        nights[0].mealID = meals[0].id
        nights[1].mealID = meals[1].id
        nights[2].mealID = meals[2].id
        let suggestions = BuildMyWeek.suggestions(night: nights[2].id, inputs: inputs(nights, meals: meals), seed: 1)
        #expect(Set(suggestions.map(\.mealID)) == [meals[3].id, meals[4].id])
    }

    @Test func suggestionsFollowTheNightsFilters() {
        let quick = (0..<2).map { LibraryMeal.fixture(name: "Quick \($0)", tags: [.quick]) }
        let slow = (0..<5).map { LibraryMeal.fixture(name: "Slow \($0)") }
        let nights = week(rushedOn: 4)
        let suggestions = BuildMyWeek.suggestions(night: nights[4].id, inputs: inputs(nights, meals: quick + slow),
                                                  seed: 9)
        #expect(Set(suggestions.map(\.mealID)) == Set(quick.map(\.id)))
        #expect(suggestions.allSatisfy { $0.reason == .quickForRushedNight })
    }

    @Test func dislikedBySomeoneHomeIsNotSuggested() {
        let meals = (0..<4).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let nights = week()
        let suggestions = BuildMyWeek.suggestions(
            night: nights[1].id, inputs: inputs(nights, meals: meals, notForMe: [meals[0].id: [nora: 1]]), seed: 2)
        #expect(!suggestions.map(\.mealID).contains(meals[0].id))
    }

    @Test func trialDishesAreSuggestedOnlyWithinTheWeeksBudget() {
        let known = (0..<5).map { LibraryMeal.fixture(name: "Known \($0)") }
        let trial = LibraryMeal.fixture(name: "Trial", status: .trial)
        var settings = plain
        settings.newDishesPerWeek = 1
        let nights = week()
        let open = BuildMyWeek.suggestions(night: nights[1].id, inputs: inputs(nights, meals: known + [trial],
                                                                                settings: settings), seed: 4, count: 6)
        #expect(open.contains { $0.mealID == trial.id && $0.reason == .somethingNew })
        var full = nights
        full[5].mealID = LibraryMeal.fixture(status: .trial).id
        let otherTrial = LibraryMeal.fixture(id: full[5].mealID!, name: "Other trial", status: .trial)
        let spent = BuildMyWeek.suggestions(night: full[1].id,
                                            inputs: inputs(full, meals: known + [trial, otherTrial], settings: settings),
                                            seed: 4, count: 6)
        #expect(!spent.contains { $0.mealID == trial.id })
    }

    @Test func pastNightsStillGetSuggestionsForLoggingWhatWasEaten() {
        let thaw = LibraryMeal.fixture(name: "Thaw first", tags: [.thawFirst])
        let recent = LibraryMeal.fixture(name: "Made that night")
        let nights = week()
        var planning = inputs(nights, meals: [thaw, recent])
        planning.today = start.adding(days: 4)
        planning.history = [MealHistory(mealID: recent.id, timesMade: 1, lastMade: start.adding(days: 1))]
        let suggestions = BuildMyWeek.suggestions(night: nights[1].id, inputs: planning, seed: 1)
        #expect(Set(suggestions.map(\.mealID)) == [thaw.id, recent.id])
    }

    @Test func fewerSuggestionsWhenFewerFit() {
        let meals = [LibraryMeal.fixture(name: "Only one")]
        let nights = week()
        #expect(BuildMyWeek.suggestions(night: nights[0].id, inputs: inputs(nights, meals: meals), seed: 1).count == 1)
        #expect(BuildMyWeek.suggestions(night: UUID(), inputs: inputs(nights, meals: meals), seed: 1).isEmpty)
    }
}

@MainActor
struct SwapStoreTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func week() -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [:])
        })
    }

    @Test func swappingToAMealSavesItLockedWithNoReason() async {
        let sent = Mutex<NightUpdate?>(nil)
        let locked = Mutex<Bool?>(nil)
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setNight: { update, lock in
                sent.withLock { $0 = update }
                locked.withLock { $0 = lock }
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let tacos = LibraryMeal.fixture(name: "Tacos")
        await store.swap(nightID: existing.nights[2].id, to: .meal(id: tacos.id, name: tacos.name))
        #expect(sent.withLock { $0 } == NightUpdate(nightID: existing.nights[2].id, mealID: tacos.id))
        #expect(store.week?.nights[2].mealName == "Tacos")
        #expect(store.week?.nights[2].locked == true, "a planner's own pick survives Rebuild")
        #expect(locked.withLock { $0 } == true)
    }

    @Test func swappingToAQuickPickReplacesTheMeal() async {
        var planned = week()
        planned.nights[3].mealID = UUID()
        planned.nights[3].mealName = "Chili"
        planned.nights[3].reason = "Due for a turn"
        let existing = planned
        let sent = Mutex<NightUpdate?>(nil)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, setNight: { update, _ in sent.withLock { $0 = update } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.swap(nightID: existing.nights[3].id, to: .quickPick(.takeout))
        #expect(sent.withLock { $0 } == NightUpdate(nightID: existing.nights[3].id, quickPick: .takeout))
        #expect(store.week?.nights[3].mealID == nil)
        #expect(store.week?.nights[3].quickPick == .takeout)
        #expect(store.week?.nights[3].reason == nil)
    }

    @Test func clearingANightUnlocksIt() async {
        var planned = week()
        planned.nights[1].quickPick = .eatOut
        planned.nights[1].locked = true
        let existing = planned
        let locked = Mutex<Bool?>(nil)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, setNight: { _, lock in locked.withLock { $0 = lock } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.swap(nightID: existing.nights[1].id, to: .empty)
        #expect(store.week?.nights[1].isPlanned == false)
        #expect(store.week?.nights[1].locked == false, "an empty night is open for Fill again")
        #expect(locked.withLock { $0 } == false)
    }

    @Test func aSuccessfulRetryClearsTheErrorAndReportsSuccess() async {
        let existing = week()
        let fail = Mutex(true)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setNight: { _, _ in if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(!(await store.swap(nightID: existing.nights[0].id, to: .quickPick(.takeout))))
        fail.withLock { $0 = false }
        #expect(await store.swap(nightID: existing.nights[0].id, to: .quickPick(.takeout)))
        #expect(store.errorMessage == nil)
    }

    @Test func noSwapWhileBuilding() async {
        let existing = week()
        let gate = AsyncStream<Void>.makeStream()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setNight: { _, _ in Issue.record("no swap while a build is saving") }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        async let building: Void = store.buildWeek {
            for await _ in gate.stream { break }
            return nil
        }
        while !store.isBuilding { await Task.yield() }
        #expect(!(await store.swap(nightID: existing.nights[0].id, to: .quickPick(.takeout))))
        gate.continuation.yield()
        await building
    }

    @Test func aFailedSwapShowsWhatTheServerHas() async {
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, setNight: { _, _ in throw URLError(.notConnectedToInternet) }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.swap(nightID: existing.nights[0].id, to: .quickPick(.takeout))
        #expect(store.week == existing)
        #expect(store.errorMessage != nil)
    }
}
