import Foundation
import Synchronization
import Testing
@testable import Foon

struct WeekLayoutTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func nights(planned: Set<Int> = []) -> [WeekNight] {
        (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil,
                      mealID: planned.contains(offset) ? UUID() : nil,
                      mealName: planned.contains(offset) ? "Meal \(offset)" : nil,
                      quickPick: nil, locked: false, attendance: [:])
        }
    }

    @Test func tonightIsOnTopThenTheRestOfTheWeekWithPastNightsSetAside() {
        let layout = WeekLayout(nights: nights(), today: sunday.adding(days: 3))
        #expect(layout.tonight?.date == sunday.adding(days: 3))
        #expect(layout.upcoming.map(\.date) == (4..<7).map { sunday.adding(days: $0) })
        #expect(layout.past.map(\.date) == (0..<3).map { sunday.adding(days: $0) })
    }

    @Test func aWeekThatHasNotStartedHasNoTonight() {
        let layout = WeekLayout(nights: nights(), today: sunday.adding(days: -2))
        #expect(layout.tonight == nil)
        #expect(layout.upcoming.count == 7)
        #expect(layout.past.isEmpty)
    }

    @Test(arguments: [
        (Set<Int>(), WeekLayout.Progress.unplanned),
        (Set([3, 4]), .partlyPlanned),
        (Set([3, 4, 5, 6]), .planned)
    ])
    func progressCountsOnlyTonightAndLater(planned: Set<Int>, progress: WeekLayout.Progress) {
        // Past nights left empty don't make a week "partly planned".
        #expect(WeekLayout(nights: nights(planned: planned), today: sunday.adding(days: 3)).progress == progress)
    }

    @Test func emptyNightsAreTheOnesStillToFill() {
        let layout = WeekLayout(nights: nights(planned: [3, 5]), today: sunday.adding(days: 3))
        #expect(layout.emptyNights.map(\.date) == [sunday.adding(days: 4), sunday.adding(days: 6)])
    }

    @Test func aQuickPickCountsAsPlanned() {
        var week = nights()
        week[3].quickPick = .takeout
        #expect(WeekLayout(nights: week, today: sunday.adding(days: 3)).emptyNights.map(\.date)
            == (4..<7).map { sunday.adding(days: $0) })
    }
}

struct NightBadgeTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)

    @Test func allergyFlagsOnlyNameWhoIsHome() {
        let mac = LibraryMeal.fixture(name: "Mac and cheese", ingredients: ["milk", "elbow macaroni"])
        let allergies = [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.milk]),
                         MemberAllergies(memberID: owen.id, firstName: "Owen", allergens: [.milk])]
        let badges = NightBadges.badges(meal: mac, library: [mac], allergies: allergies, home: [nora.id])
        #expect(badges == [.allergy("Contains milk (Nora)")])
        #expect(NightBadges.badges(meal: mac, library: [mac], allergies: allergies, home: []).isEmpty)
    }

    @Test func prepStepsBecomeAPrepBadge() {
        let chicken = LibraryMeal.fixture(name: "Grilled chicken",
                                          prepSteps: [PrepStep(step: "Move the chicken to the fridge to thaw", leadHours: 24)])
        #expect(NightBadges.badges(meal: chicken, library: [chicken], allergies: [], home: [])
            == [.prep("Move the chicken to the fridge to thaw · 1 day ahead")])
    }
}

@MainActor
struct WeekStoreLockTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func week() -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [:])
        })
    }

    @Test func lockingANightShowsAtOnceAndIsSent() async {
        let sent = Mutex<[Bool]>([])
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setLocked: { _, locked in sent.withLock { $0.append(locked) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.toggleLock(nightID: existing.nights[2].id)
        #expect(store.week?.nights[2].locked == true)
        #expect(sent.withLock { $0 } == [true])
    }

    @Test func setEffortGoesStraightToTheChosenEffort() async {
        let sent = Mutex<[NightEffort]>([])
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setEffort: { _, effort in sent.withLock { $0.append(effort) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.setEffort(.event, nightID: existing.nights[2].id)
        #expect(store.week?.nights[2].effort == .event)
        #expect(sent.withLock { $0 } == [.event])
        await store.setEffort(.event, nightID: existing.nights[2].id)
        #expect(sent.withLock { $0 } == [.event], "no change, nothing sent")
    }

    @Test func layoutFollowsTheStoresToday() async {
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in existing }),
                              today: { CalendarDay(year: 2026, month: 11, day: 4) })
        await store.load(settings: HouseholdSettings())
        #expect(store.layout?.tonight?.date == CalendarDay(year: 2026, month: 11, day: 4))
    }
}

@MainActor
struct BuildMyWeekStoreTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)
    private let ann = Member.fixture(firstName: "Ann", guardian: true, role: .planner)
    private let meals = (1...10).map { LibraryMeal.fixture(name: "Meal \($0)", tags: [.quick]) }

    private func emptyWeek() -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [ann.id: true])
        })
    }

    private var context: PlanningContext {
        PlanningContext(meals: meals, history: [], settings: HouseholdSettings(), members: [ann])
    }

    private func store(_ client: WeekClient) -> WeekStore {
        WeekStore(householdID: Household.sample.id, client: client, today: { sunday }, seed: { 42 })
    }

    @Test func buildingAWeekSavesAPickAndReasonForEveryNight() async {
        let sent = Mutex<[NightUpdate]>([])
        let week = emptyWeek()
        let store = store(.fake(week: { _, _ in week }, setNights: { _, updates in sent.withLock { $0 = updates } }))
        await store.load(settings: HouseholdSettings())
        await store.buildWeek { context }
        let updates = sent.withLock { $0 }
        #expect(updates.count == 7)
        #expect(updates.allSatisfy { $0.mealID != nil || $0.quickPick != nil })
        #expect(updates.allSatisfy { $0.reason != nil })
        #expect(store.week?.nights.allSatisfy(\.isPlanned) == true)
        #expect(store.week?.nights.compactMap(\.mealID).allSatisfy { id in meals.contains { $0.id == id } } == true)
    }

    @Test func buildingWithNoWeekStartsItFirst() async {
        let created = emptyWeek()
        let sent = Mutex(0)
        let store = store(.fake(week: { _, _ in nil }, create: { _, _ in created },
                                setNights: { _, updates in sent.withLock { $0 = updates.count } }))
        await store.load(settings: HouseholdSettings())
        await store.buildWeek { context }
        #expect(store.week?.planID == created.planID)
        #expect(sent.withLock { $0 } == 7)
    }

    @Test func buildingRemembersWhichNightsItPlacedAsRequests() async {
        let week = emptyWeek()
        let store = store(.fake(week: { _, _ in week }))
        await store.load(settings: HouseholdSettings())
        var context = context
        let idea = UUID()
        context.requests = [DatedRequest(mealID: meals[3].id, date: sunday.adding(days: 3), requesterID: ann.id,
                                         requestID: idea)]
        await store.buildWeek { context }
        #expect(store.requestNights == [idea: week.nights[3].id], "only the request's night, not other picks")
        await store.swap(nightID: week.nights[3].id, to: .quickPick(.takeout))
        #expect(store.requestNights.isEmpty, "a swap on that night takes the request off it")
    }

    @Test func fillingRemainingNightsLeavesPlannedOnesAlone() async {
        var week = emptyWeek()
        week.nights[2].mealID = meals[0].id
        week.nights[2].mealName = meals[0].name
        week.nights[4].quickPick = .eatOut
        let existing = week
        let sent = Mutex<[NightUpdate]>([])
        let store = store(.fake(week: { _, _ in existing }, setNights: { _, updates in sent.withLock { $0 = updates } }))
        await store.load(settings: HouseholdSettings())
        await store.fillRemaining { context }
        let touched = Set(sent.withLock { $0 }.map(\.nightID))
        #expect(!touched.contains(existing.nights[2].id))
        #expect(!touched.contains(existing.nights[4].id))
        #expect(touched.count == 5)
        #expect(store.week?.nights[2].mealID == meals[0].id)
        #expect(store.week?.nights[4].quickPick == .eatOut)
    }

    @Test func shuffleChangesOnlyItsNight() async {
        var week = emptyWeek()
        for index in week.nights.indices {
            week.nights[index].mealID = meals[index].id
            week.nights[index].mealName = meals[index].name
        }
        let existing = week
        let sent = Mutex<[NightUpdate]>([])
        let store = store(.fake(week: { _, _ in existing }, setNights: { _, updates in sent.withLock { $0 = updates } }))
        await store.load(settings: HouseholdSettings())
        await store.shuffle(nightID: existing.nights[3].id) { context }
        let updates = sent.withLock { $0 }
        #expect(updates.map(\.nightID) == [existing.nights[3].id])
        #expect(updates.first?.mealID != meals[3].id)
        #expect(store.week?.nights[3].mealID == updates.first?.mealID)
        #expect(store.week?.nights.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element.mealID == meals[$0.offset].id } == true)
    }

    @Test func aFailedSaveShowsWhatTheServerHas() async {
        let week = emptyWeek()
        let store = store(.fake(week: { _, _ in week }, setNights: { _, _ in throw URLError(.notConnectedToInternet) }))
        await store.load(settings: HouseholdSettings())
        await store.buildWeek { context }
        #expect(store.week == week)
        #expect(store.errorMessage != nil)
    }

    @Test func anEmptyLibraryNeverClearsThePlan() async {
        var week = emptyWeek()
        week.nights[1].mealID = meals[0].id
        week.nights[1].mealName = meals[0].name
        let existing = week
        let store = store(.fake(week: { _, _ in existing },
                                setNights: { _, _ in Issue.record("nothing should be written") }))
        await store.load(settings: HouseholdSettings())
        let empty = PlanningContext(meals: [], history: [], settings: HouseholdSettings(), members: [ann])
        await store.buildWeek { empty }
        #expect(store.week == existing)
        #expect(store.errorMessage != nil)
        await store.buildWeek { nil }
        #expect(store.week == existing, "a library that didn't load builds nothing")
    }

    @Test func aNightThatAlreadyHasDinnerIsNeverClearedByADraft() async {
        // Only one meal fits, so a rebuild finds nothing for the other planned nights; they keep what they had.
        let only = [LibraryMeal.fixture(name: "Only one", tags: [.quick])]
        var week = emptyWeek()
        for index in 0..<3 {
            week.nights[index].mealID = meals[index].id
            week.nights[index].mealName = meals[index].name
        }
        let existing = week
        let sent = Mutex<[NightUpdate]>([])
        let store = store(.fake(week: { _, _ in existing }, setNights: { _, updates in sent.withLock { $0 = updates } }))
        await store.load(settings: HouseholdSettings())
        await store.buildWeek { PlanningContext(meals: only, history: [], settings: HouseholdSettings(), members: [self.ann]) }
        #expect(sent.withLock { $0 }.allSatisfy { $0.mealID != nil || $0.quickPick != nil })
        #expect(store.week?.nights.prefix(3).allSatisfy(\.isPlanned) == true)
    }

    @Test func aRequestedDishIsSaved() async {
        let week = emptyWeek()
        let sent = Mutex<[NightUpdate]>([])
        let store = store(.fake(week: { _, _ in week }, setNights: { _, updates in sent.withLock { $0 = updates } }))
        await store.load(settings: HouseholdSettings())
        let request = DatedRequest(mealID: meals[5].id, date: sunday.adding(days: 4), requesterID: ann.id)
        await store.buildWeek {
            PlanningContext(meals: self.meals, history: [], settings: HouseholdSettings(), members: [self.ann],
                            requests: [request])
        }
        #expect(sent.withLock { $0 }.contains { $0.nightID == week.nights[4].id && $0.mealID == meals[5].id })
    }

    @Test func buildingShowsWhileTheLibraryLoads() async {
        let week = emptyWeek()
        let gate = AsyncStream<Void>.makeStream()
        let store = store(.fake(week: { _, _ in week }))
        await store.load(settings: HouseholdSettings())
        async let building: Void = store.buildWeek {
            for await _ in gate.stream { break }
            return nil
        }
        while !store.isBuilding { await Task.yield() }
        await store.buildWeek { Issue.record("a second build waits"); return nil }
        gate.continuation.yield()
        await building
        #expect(!store.isBuilding)
    }

    @Test func nightsNothingFitIsRememberedUntilTheyArePlanned() async {
        let only = [LibraryMeal.fixture(name: "Only one", tags: [.quick])]
        let existing = emptyWeek()
        let store = store(.fake(week: { _, _ in existing }))
        await store.load(settings: HouseholdSettings())
        var plain = HouseholdSettings()
        plain.leftoverNights = 0
        let settings = plain
        await store.buildWeek { PlanningContext(meals: only, history: [], settings: settings, members: [self.ann]) }
        #expect(store.unfillableNights.count == 6)
        let open = store.week!.nights.first { !$0.isPlanned }!
        await store.swap(nightID: open.id, to: .quickPick(.takeout))
        #expect(store.unfillableNights.count == 5)
    }

    @Test func reasonsShowOnTheCard() {
        var night = emptyWeek().nights[0]
        night.mealID = meals[0].id
        night.mealName = meals[0].name
        night.reason = "Haven't had it in 3 weeks"
        #expect(WeekStore.slot(for: night, sides: []) == .meal(name: meals[0].name, photoURL: nil,
                                                              reason: "Haven't had it in 3 weeks", sides: []))
    }

    @Test func planningInputsCarryTheWeekAndTheFamily() {
        let week = emptyWeek()
        let inputs = context.inputs(for: week, today: sunday.adding(days: 2))
        #expect(inputs.nights.count == 7)
        #expect(inputs.today == sunday.adding(days: 2))
        #expect(inputs.memberNames[ann.id] == "Ann")
    }
}
