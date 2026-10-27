import Foundation
import Synchronization
import Testing
@testable import Foon

struct TraditionDraftTests {
    /// Sunday 2026-11-01; Tuesday is ISO weekday 2 (offset 2), Friday is 5 (offset 5).
    private let start = CalendarDay(year: 2026, month: 11, day: 1)
    private let mom = UUID()

    private var plain: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.takeoutNights = 0
        return settings
    }

    private func week() -> [PlanningNight] {
        (0..<7).map { PlanningNight(id: UUID(), date: start.adding(days: $0), attendance: [mom: true]) }
    }

    private func inputs(_ nights: [PlanningNight], meals: [LibraryMeal], traditions: [Tradition],
                        requests: [DatedRequest] = [], settings: HouseholdSettings? = nil) -> PlanningInputs {
        PlanningInputs(nights: nights, meals: meals,
                       history: meals.map { MealHistory(mealID: $0.id, timesMade: 3, lastMade: start.adding(days: -30)) },
                       settings: settings ?? plain, memberNames: [mom: "Mom"], requests: requests,
                       traditions: traditions)
    }

    @Test func isoWeekdaysComeFromTheDateAlone() {
        #expect(start.isoWeekday == 7)
        #expect(start.adding(days: 2).isoWeekday == 2)
        #expect(CalendarDay(year: 2024, month: 2, day: 29).isoWeekday == 4)
    }

    @Test func aTraditionFillsItsWeekdayLockedWithItsName() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let others = (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let nights = week()
        let draft = BuildMyWeek.draft(inputs(nights, meals: [tacos] + others,
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: "Taco Tuesday")]),
                                      seed: 1)
        #expect(draft[2].pick == .meal(tacos.id))
        #expect(draft[2].reason == .tradition(name: "Taco Tuesday"))
        #expect(draft[2].locks)
        #expect(draft.filter(\.locks).count == 1)
        #expect(!draft.enumerated().contains { $0.offset != 2 && $0.element.pick == .meal(tacos.id) })
    }

    @Test func aQuickPickTraditionCountsTowardTheSetting() {
        var settings = plain
        settings.takeoutNights = 1
        let meals = (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let draft = BuildMyWeek.draft(inputs(week(), meals: meals,
                                             traditions: [Tradition(weekday: 5, pick: .quickPick(.takeout), name: nil)],
                                             settings: settings), seed: 2)
        #expect(draft[5].pick == .quickPick(.takeout))
        #expect(draft[5].reason == .tradition(name: nil))
        #expect(draft.filter { $0.pick == .quickPick(.takeout) }.count == 1, "the tradition is the week's takeout")
    }

    @Test func aDatedRequestWinsItsNight() {
        let tacos = LibraryMeal.fixture(name: "Tacos"), steak = LibraryMeal.fixture(name: "Steak")
        let others = (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let nights = week()
        let draft = BuildMyWeek.draft(inputs(nights, meals: [tacos, steak] + others,
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)],
                                             requests: [DatedRequest(mealID: steak.id, date: nights[2].date, requesterID: mom)]),
                                      seed: 3)
        #expect(draft[2].pick == .meal(steak.id))
    }

    @Test func aRetiredOrArchivedTraditionMealIsSkipped() {
        let tacos = LibraryMeal.fixture(name: "Tacos", status: .archived)
        let others = (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let draft = BuildMyWeek.draft(inputs(week(), meals: [tacos] + others,
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)]),
                                      seed: 4)
        #expect(draft[2].pick != .meal(tacos.id))
        #expect(!draft[2].locks)
    }

    @Test func lockedPastAndEventNightsAreLeftAlone() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var nights = week()
        nights[2].locked = true
        nights[2].quickPick = .eatOut
        let draft = BuildMyWeek.draft(inputs(nights, meals: [tacos],
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)]),
                                      seed: 5)
        #expect(draft[2].pick == .quickPick(.eatOut))
        #expect(!draft[2].locks)
    }

    @Test func traditionsLandEveryWeekTheWeekdayAppears() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        // A week starting Tuesday still has its one Tuesday first.
        let nights = (0..<7).map {
            PlanningNight(id: UUID(), date: start.adding(days: 2 + $0), attendance: [mom: true])
        }
        let draft = BuildMyWeek.draft(inputs(nights, meals: [tacos] + (0..<8).map { LibraryMeal.fixture(name: "D\($0)") },
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)]),
                                      seed: 6)
        #expect(draft[0].pick == .meal(tacos.id))
    }

    @Test func aTraditionSitsOutANightSomeoneHomeSaidNotForMe() {
        let liver = LibraryMeal.fixture(name: "Liver")
        let others = (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        var planning = inputs(week(), meals: [liver] + others,
                              traditions: [Tradition(weekday: 2, pick: .meal(liver.id), name: nil)])
        planning.notForMe = [liver.id: [mom: 1]]
        let draft = BuildMyWeek.draft(planning, seed: 7)
        #expect(draft[2].pick != .meal(liver.id))
        #expect(!draft[2].locks)
    }

    @Test func aSnoozedTraditionSitsOutTheWeek() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var planning = inputs(week(), meals: [tacos] + (0..<8).map { LibraryMeal.fixture(name: "D\($0)") },
                              traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)])
        planning.snoozedMealIDs = [tacos.id]
        #expect(BuildMyWeek.draft(planning, seed: 8)[2].pick != .meal(tacos.id))
    }

    @Test func aTraditionMealRequestedOnAnotherNightIsNotDoubled() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let nights = week()
        let draft = BuildMyWeek.draft(inputs(nights, meals: [tacos] + (0..<8).map { LibraryMeal.fixture(name: "D\($0)") },
                                             traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: nil)],
                                             requests: [DatedRequest(mealID: tacos.id, date: nights[4].date, requesterID: mom)]),
                                      seed: 9)
        #expect(draft[4].pick == .meal(tacos.id))
        #expect(draft[2].pick != .meal(tacos.id))
        #expect(draft.filter { $0.pick == .meal(tacos.id) }.count == 1)
    }

    @Test func namesAreTrimmedAndCappedLikeTheDatabase() {
        #expect(Tradition.cleanedName("  Taco Tuesday ") == "Taco Tuesday")
        #expect(Tradition.cleanedName("   ") == nil)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 10)
        let capped = Tradition.cleanedName(family)
        #expect((capped?.unicodeScalars.count ?? 0) <= 40)
        #expect(capped?.allSatisfy { $0 == "👨‍👩‍👧‍👦" } == true, "never splits an emoji")
    }

    @Test func traditionReasonsRead() {
        #expect(PlanReason.tradition(name: "Taco Tuesday").text == "Taco Tuesday")
        #expect(PlanReason.tradition(name: nil).text == "Tradition")
    }
}

@MainActor
struct TraditionStoreTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    @Test func buildSavesTraditionNightsLocked() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let meals = [tacos] + (0..<8).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let existing = Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [:])
        })
        let sent = Mutex<[NightUpdate]>([])
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, setNights: { _, updates in sent.withLock { $0 = updates } }
        ), today: { sunday }, seed: { 1 })
        await store.load(settings: HouseholdSettings())
        await store.buildWeek {
            PlanningContext(meals: meals, history: [], settings: HouseholdSettings(), members: [],
                            traditions: [Tradition(weekday: 2, pick: .meal(tacos.id), name: "Taco Tuesday")])
        }
        let tuesday = sent.withLock { $0 }.first { $0.nightID == existing.nights[2].id }
        #expect(tuesday?.mealID == tacos.id)
        #expect(tuesday?.locked == true)
        #expect(tuesday?.reason == "Taco Tuesday")
        #expect(sent.withLock { $0 }.filter { $0.locked == true }.count == 1)
        #expect(store.week?.nights[2].locked == true)
    }

    @Test func traditionsLoadWithTheWeekAndCanBeSetAndRemoved() async {
        let saved = Mutex<[Int: Tradition?]>([:])
        let tacos = Tradition(weekday: 2, pick: .quickPick(.takeout), name: "Takeout Tuesday")
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in nil },
            traditions: { _ in [tacos] },
            setTradition: { _, weekday, tradition in saved.withLock { $0[weekday] = .some(tradition) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(store.traditions == [tacos])
        #expect(store.tradition(on: 2) == tacos)
        let pizza = Tradition(weekday: 5, pick: .quickPick(.eatOut), name: "Pizza Friday")
        #expect(await store.setTradition(pizza, on: 5))
        #expect(store.tradition(on: 5) == pizza)
        #expect(await store.setTradition(nil, on: 2))
        #expect(store.tradition(on: 2) == nil)
        #expect(saved.withLock { $0 }[5] == .some(pizza))
        #expect(saved.withLock { $0 }[2] == .some(nil))
    }

    @Test func traditionsThatFailToLoadSaySo() async {
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in nil }, traditions: { _ in throw URLError(.notConnectedToInternet) }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(store.errorMessage != nil)
        #expect(!store.traditionsLoaded)
    }

    @Test func aFailedTraditionSaveKeepsTheOldOne() async {
        let tacos = Tradition(weekday: 2, pick: .quickPick(.takeout), name: nil)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in nil },
            traditions: { _ in [tacos] },
            setTradition: { _, _, _ in throw URLError(.notConnectedToInternet) }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(!(await store.setTradition(nil, on: 2)))
        #expect(store.tradition(on: 2) == tacos)
        #expect(store.errorMessage != nil)
    }

    @Test func traditionsDecodeFromTheirRows() throws {
        let id = UUID()
        let json = #"[{"weekday": 2, "meal_id": "\#(id.uuidString)", "quick_pick": null, "name": "Taco Tuesday"},"#
            + #"{"weekday": 5, "meal_id": null, "quick_pick": "takeout", "name": null}]"#
        let traditions = try JSONDecoder().decode([Tradition].self, from: Data(json.utf8))
        #expect(traditions == [Tradition(weekday: 2, pick: .meal(id), name: "Taco Tuesday"),
                               Tradition(weekday: 5, pick: .quickPick(.takeout), name: nil)])
    }
}
