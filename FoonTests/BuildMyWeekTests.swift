import Foundation
import Testing
@testable import Foon

struct BuildMyWeekTests {
    /// Sunday, the default shopping day.
    private let start = CalendarDay(year: 2026, month: 11, day: 1)
    private let mom = UUID(), dad = UUID(), nora = UUID()
    private var family: [UUID] { [mom, dad, nora] }
    private var names: [UUID: String] { [mom: "Mom", dad: "Dad", nora: "Nora"] }

    /// No special slots, so tests of the filters and scoring see only the regular fill.
    private var plain: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.takeoutNights = 0
        return settings
    }

    private func settings(new: Int = 0, leftovers: Int = 0, takeout: Int = 0) -> HouseholdSettings {
        var settings = plain
        settings.newDishesPerWeek = new
        settings.leftoverNights = leftovers
        settings.takeoutNights = takeout
        return settings
    }

    private func week(efforts: [Int: NightEffort] = [:], away: [Int: Set<UUID>] = [:]) -> [PlanningNight] {
        (0..<7).map { offset in
            PlanningNight(
                id: UUID(), date: start.adding(days: offset), effort: efforts[offset] ?? .normal,
                attendance: Dictionary(uniqueKeysWithValues: family.map { ($0, !(away[offset] ?? []).contains($0)) })
            )
        }
    }

    private func made(_ meal: LibraryMeal, daysAgo: Int, times: Int = 4) -> MealHistory {
        MealHistory(mealID: meal.id, timesMade: times, lastMade: start.adding(days: -daysAgo))
    }

    /// Known dishes, all made long enough ago to be outside the repeat window.
    private func regulars(_ count: Int, tags: [MealTag] = []) -> [LibraryMeal] {
        (0..<count).map { LibraryMeal.fixture(name: "Dish \($0)", tags: tags) }
    }

    private func inputs(
        nights: [PlanningNight]? = nil, meals: [LibraryMeal], history: [MealHistory]? = nil,
        settings: HouseholdSettings? = nil
    ) -> PlanningInputs {
        PlanningInputs(nights: nights ?? week(), meals: meals,
                       history: history ?? meals.enumerated().map { made($1, daysAgo: 20 + $0) },
                       settings: settings ?? plain, memberNames: names)
    }

    private func mealIDs(_ draft: [NightPlan]) -> [UUID?] { draft.map(\.pick?.mealID) }

    // MARK: Determinism

    @Test func theSameSeedGivesTheSameDraft() {
        let planning = inputs(meals: regulars(12), settings: settings(new: 0, leftovers: 1, takeout: 1))
        #expect(BuildMyWeek.draft(planning, seed: 42) == BuildMyWeek.draft(planning, seed: 42))
    }

    @Test func differentSeedsCanGiveDifferentDrafts() {
        let planning = inputs(meals: regulars(12))
        let drafts = Set((0..<20).map { mealIDs(BuildMyWeek.draft(planning, seed: $0)) })
        #expect(drafts.count > 1)
    }

    @Test func theGeneratorRepeatsItsSequenceForASeed() {
        var first = SeededGenerator(seed: 7), second = SeededGenerator(seed: 7), other = SeededGenerator(seed: 8)
        let sequence = (0..<5).map { _ in first.next() }
        #expect(sequence == (0..<5).map { _ in second.next() })
        #expect(sequence != (0..<5).map { _ in other.next() })
    }

    @Test func theDraftComesBackInDateOrder() {
        let planning = inputs(nights: week().reversed(), meals: regulars(8))
        let dates = BuildMyWeek.draft(planning, seed: 1).map(\.date)
        #expect(dates == dates.sorted())
        #expect(dates.first == start)
    }

    // MARK: Lock

    @Test func pinnedAndEventNightsAreUntouched() {
        let meals = regulars(10)
        var nights = week()
        nights[1].locked = true
        nights[1].mealID = meals[0].id
        nights[4].effort = .event
        nights[4].quickPick = .eatOut
        nights[6].effort = .event
        for seed in UInt64(0)..<50 {
            let draft = BuildMyWeek.draft(inputs(nights: nights, meals: meals), seed: seed)
            #expect(draft[1] == NightPlan(nightID: nights[1].id, date: nights[1].date, pick: .meal(meals[0].id),
                                          reason: nil, isKept: true))
            #expect(draft[4].pick == .quickPick(.eatOut) && draft[4].isKept && draft[4].reason == nil)
            #expect(draft[6].pick == nil && draft[6].isKept, "An empty event night stays empty")
            #expect(mealIDs(draft).filter { $0 == meals[0].id }.count == 1, "A pinned meal isn't repeated")
        }
    }

    @Test func anUnlockedNightIsRedrawnEvenIfItHadAMeal() {
        let meals = regulars(10)
        var nights = week()
        nights[2].mealID = meals[0].id
        let draft = BuildMyWeek.draft(inputs(nights: nights, meals: meals), seed: 3)
        #expect(!draft[2].isKept)
        #expect(draft[2].reason != nil)
    }

    @Test func aDatedRequestLandsOnItsNightAndIsKept() {
        let meals = regulars(10)
        var planning = inputs(meals: meals)
        planning.requests = [DatedRequest(mealID: meals[3].id, date: start.adding(days: 5), requesterID: dad)]
        let draft = BuildMyWeek.draft(planning, seed: 9)
        #expect(draft[5].pick == .meal(meals[3].id))
        #expect(draft[5].reason == .request(name: "Dad"))
        #expect(draft[5].isKept)
        #expect(mealIDs(draft).filter { $0 == meals[3].id }.count == 1)
    }

    @Test func aRequestForARetiredDishOrALockedNightIsSkipped() {
        let meals = regulars(8) + [.fixture(name: "Liver", status: .retired)]
        var nights = week()
        nights[2].locked = true
        var planning = inputs(nights: nights, meals: meals)
        planning.requests = [DatedRequest(mealID: meals[8].id, date: start.adding(days: 1), requesterID: dad),
                             DatedRequest(mealID: meals[0].id, date: start.adding(days: 2), requesterID: dad)]
        let draft = BuildMyWeek.draft(planning, seed: 2)
        #expect(!mealIDs(draft).contains(meals[8].id))
        #expect(draft[2].pick == nil && draft[2].reason == nil)
    }

    // MARK: Filters

    @Test func rushedNightsGetOnlyQuickMeals() {
        let quick = regulars(3, tags: [.quick])
        let meals = quick + regulars(8)
        let nights = week(efforts: [1: .rushed, 3: .rushed, 5: .rushed])
        for seed in UInt64(0)..<100 {
            let draft = BuildMyWeek.draft(inputs(nights: nights, meals: meals), seed: seed)
            for index in [1, 3, 5] {
                #expect(quick.contains { $0.id == draft[index].pick?.mealID })
                #expect(draft[index].reason == .quickForRushedNight)
            }
        }
    }

    @Test func dishesInsideTheRepeatWindowWaitUntilItPasses() {
        let recent = LibraryMeal.fixture(name: "Tacos")
        let others = regulars(10)
        // Made 8 days before the week: still in the 10-day window on nights 0 and 1, out of it from night 2.
        let history = [made(recent, daysAgo: 8)] + others.map { made($0, daysAgo: 30) }
        var placed = 0
        for seed in UInt64(0)..<200 {
            let draft = BuildMyWeek.draft(inputs(meals: [recent] + others, history: history), seed: seed)
            guard let index = draft.firstIndex(where: { $0.pick == .meal(recent.id) }) else { continue }
            #expect(index >= 2)
            placed += 1
        }
        #expect(placed > 0, "Out of the window it's a candidate again")
    }

    @Test func noMealAppearsTwiceInADraft() {
        for seed in UInt64(0)..<100 {
            let ids = mealIDs(BuildMyWeek.draft(inputs(meals: regulars(9), settings: settings(new: 0, leftovers: 1)),
                                                seed: seed)).compactMap { $0 }
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func snoozedDishesAreSkipped() {
        let meals = regulars(9)
        var planning = inputs(meals: meals)
        planning.snoozedMealIDs = [meals[0].id, meals[1].id]
        for seed in UInt64(0)..<50 {
            let ids = mealIDs(BuildMyWeek.draft(planning, seed: seed))
            #expect(!ids.contains(meals[0].id) && !ids.contains(meals[1].id))
        }
    }

    @Test func aDislikedDishOnlyLandsOnNightsTheDislikerIsAway() {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var planning = inputs(nights: week(away: [3: [nora]]), meals: [tacos])
        planning.notForMe = [tacos.id: [nora: 1]]
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.firstIndex { $0.pick == .meal(tacos.id) } == 3)
            #expect(draft.filter { $0.pick == nil }.allSatisfy { $0.reason == .nothingFits })
        }
    }

    @Test func retiredAndArchivedDishesAreNeverPicked() {
        let active = regulars(3)
        let gone: [LibraryMeal] = [.fixture(name: "Liver", status: .retired), .fixture(name: "Old", status: .archived)]
        for seed in UInt64(0)..<50 {
            let ids = mealIDs(BuildMyWeek.draft(inputs(meals: active + gone), seed: seed))
            #expect(!ids.contains(gone[0].id) && !ids.contains(gone[1].id))
        }
    }

    @Test func thawFirstDishesSkipTheShoppingNight() {
        let roast = LibraryMeal.fixture(name: "Pot roast", tags: [.thawFirst])
        let marinated = LibraryMeal.fixture(name: "Kebabs", prepSteps: [PrepStep(step: "Marinate", leadHours: 24)])
        let slowCooker = LibraryMeal.fixture(name: "Chili", prepSteps: [PrepStep(step: "Start it", leadHours: 8)])
        let firstNight = Array(week().prefix(1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(inputs(nights: firstNight, meals: [roast, marinated, slowCooker]), seed: seed)
            #expect(draft[0].pick == .meal(slowCooker.id), "Short prep fits the first night")
        }
    }

    @Test func grillDishesFitAnyNight() {
        let burgers = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let draft = BuildMyWeek.draft(inputs(nights: Array(week().prefix(1)), meals: [burgers]), seed: 0)
        #expect(draft[0].pick == .meal(burgers.id))
    }

    @Test func nightsWithNothingThatFitsStayEmptyWithAReason() {
        let nights = week(efforts: Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, NightEffort.rushed) }))
        let draft = BuildMyWeek.draft(inputs(nights: nights, meals: regulars(5)), seed: 1)
        #expect(draft.allSatisfy { $0.pick == nil && $0.reason == .nothingFits && !$0.isKept })
    }

    @Test func anEmptyLibraryGivesAnEmptyWeek() {
        let draft = BuildMyWeek.draft(inputs(meals: [], settings: HouseholdSettings()), seed: 1)
        #expect(draft.count == 7)
        #expect(draft.allSatisfy { $0.pick?.mealID == nil })
    }

    // MARK: Special slots

    @Test func leftoversFollowABigBatchAndPreferARushedNight() {
        let chili = LibraryMeal.fixture(name: "Chili", tags: [.leftovers])
        let meals = [chili] + regulars(8) + regulars(2, tags: [.quick])
        let planning = inputs(nights: week(efforts: [4: .rushed]), meals: meals, settings: settings(leftovers: 1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft[3].pick == .meal(chili.id) && draft[3].reason == .bigBatch)
            #expect(draft[4].pick == .quickPick(.leftovers) && draft[4].reason == .leftoversAfterBigBatch)
            #expect(draft.filter { $0.pick == .quickPick(.leftovers) }.count == 1)
        }
    }

    @Test func leftoversFollowAPinnedBigBatch() {
        let chili = LibraryMeal.fixture(name: "Chili", tags: [.leftovers])
        var nights = week()
        nights[2].locked = true
        nights[2].mealID = chili.id
        let draft = BuildMyWeek.draft(inputs(nights: nights, meals: [chili] + regulars(8),
                                             settings: settings(leftovers: 1)), seed: 5)
        #expect(draft[3].pick == .quickPick(.leftovers) && draft[3].reason == .leftoversAfterBigBatch)
    }

    @Test func withoutABigBatchLeftoversGoOnTheMostRushedNight() {
        let planning = inputs(nights: week(efforts: [2: .rushed]), meals: regulars(8) + regulars(2, tags: [.quick]),
                              settings: settings(leftovers: 1))
        let draft = BuildMyWeek.draft(planning, seed: 4)
        #expect(draft[2].pick == .quickPick(.leftovers) && draft[2].reason == .leftoversNight)
    }

    @Test func withoutABigBatchOrRushedNightLeftoversGoLateInTheWeek() {
        let draft = BuildMyWeek.draft(inputs(meals: regulars(8), settings: settings(leftovers: 1)), seed: 4)
        #expect(draft[6].pick == .quickPick(.leftovers))
    }

    @Test func aPinnedLeftoversNightCountsTowardTheSetting() {
        var nights = week()
        nights[1].locked = true
        nights[1].quickPick = .leftovers
        let draft = BuildMyWeek.draft(inputs(nights: nights, meals: regulars(8), settings: settings(leftovers: 1)),
                                      seed: 4)
        #expect(draft.filter { $0.pick == .quickPick(.leftovers) }.count == 1)
    }

    @Test func takeoutGoesOnTheRushedNight() {
        let planning = inputs(nights: week(efforts: [5: .rushed]), meals: regulars(8), settings: settings(takeout: 1))
        let draft = BuildMyWeek.draft(planning, seed: 1)
        #expect(draft[5].pick == .quickPick(.takeout) && draft[5].reason == .takeoutOnBusiestNight)
        #expect(draft.filter { $0.pick == .quickPick(.takeout) }.count == 1)
    }

    @Test func withoutARushedNightTakeoutGoesWhereMostPeopleAreHome() {
        let away = Dictionary(uniqueKeysWithValues: [0, 1, 2, 3, 4, 6].map { ($0, Set([dad])) })
        let planning = inputs(nights: week(away: away), meals: regulars(8), settings: settings(takeout: 1))
        #expect(BuildMyWeek.draft(planning, seed: 1)[5].pick == .quickPick(.takeout))
    }

    @Test func newDishesLandOnFullAttendanceNights() {
        let trials = (0..<3).map { LibraryMeal.fixture(name: "Trial \($0)", status: .trial) }
        let neverMade = LibraryMeal.fixture(name: "Never made")
        let known = regulars(8)
        let away = Dictionary(uniqueKeysWithValues: [0, 1, 3, 4, 6].map { ($0, Set([nora])) })
        let planning = inputs(nights: week(away: away), meals: known + trials + [neverMade],
                              history: known.map { made($0, daysAgo: 30) }, settings: settings(new: 2))
        let newIDs = Set((trials + [neverMade]).map(\.id))
        for seed in UInt64(0)..<50 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            let newNights = draft.indices.filter { draft[$0].pick?.mealID.map(newIDs.contains) ?? false }
            #expect(newNights == [2, 5])
            #expect(newNights.allSatisfy { draft[$0].reason == .somethingNew })
        }
    }

    @Test func aFreshLibraryStillFillsTheWeek() {
        let fresh = regulars(9)
        let draft = BuildMyWeek.draft(inputs(meals: fresh, history: [], settings: settings(new: 1)), seed: 3)
        #expect(draft.allSatisfy { $0.pick?.mealID != nil && $0.reason == .somethingNew })
    }

    // MARK: Scoring and reasons

    @Test func aDishNotMadeInSixtyDaysIsPickedMoreThanOneMadeElevenDaysAgo() {
        let old = LibraryMeal.fixture(name: "Pot roast"), recent = LibraryMeal.fixture(name: "Tacos")
        let planning = inputs(nights: Array(week().prefix(1)), meals: [recent, old],
                              history: [made(old, daysAgo: 60), made(recent, daysAgo: 11)])
        let oldPicks = (UInt64(0)..<200).filter { BuildMyWeek.draft(planning, seed: $0)[0].pick == .meal(old.id) }
        // Expected share is 60 / 71 ≈ 85%.
        #expect(oldPicks.count > 140)
    }

    @Test func aFavoriteOfSomeoneHomeIsPickedMoreOften() {
        let meals = regulars(2)
        var planning = inputs(nights: Array(week().prefix(1)), meals: meals,
                              history: meals.map { made($0, daysAgo: 30) })
        planning.favorites = [nora: [meals[1].id]]
        let picks = (UInt64(0)..<200).filter { BuildMyWeek.draft(planning, seed: $0)[0].pick == .meal(meals[1].id) }
        #expect(picks.count > 120, "Expected share is 3 / 4")
        #expect(BuildMyWeek.draft(planning, seed: picks.first ?? 0)[0].reason == .favorite(name: "Nora"))
    }

    @Test func ingredientsOnHandBoostADish() {
        let stocked = LibraryMeal.fixture(name: "Spaghetti", ingredients: ["spaghetti", "sauce"])
        let other = LibraryMeal.fixture(name: "Curry", ingredients: ["rice"])
        var planning = inputs(nights: Array(week().prefix(1)), meals: [stocked, other],
                              history: [made(stocked, daysAgo: 30), made(other, daysAgo: 30)])
        planning.onHandItemIDs = Set(stocked.ingredients.map(\.itemID))
        let picks = (UInt64(0)..<200).filter { BuildMyWeek.draft(planning, seed: $0)[0].pick == .meal(stocked.id) }
        #expect(picks.count > 110, "Expected share is 2 / 3")
        #expect(BuildMyWeek.draft(planning, seed: picks[0])[0].reason == .usesWhatsOnHand)
    }

    @Test func everyFilledNightHasAReason() {
        let meals = [LibraryMeal.fixture(name: "Chili", tags: [.leftovers])] + regulars(10)
            + regulars(3, tags: [.quick]) + [.fixture(name: "Trial", status: .trial)]
        let planning = inputs(nights: week(efforts: [2: .rushed, 5: .full]), meals: meals,
                              history: meals.filter { $0.status == .active }.map { made($0, daysAgo: 25) },
                              settings: settings(new: 1, leftovers: 1, takeout: 1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.allSatisfy { $0.reason != nil && !($0.reason?.text.isEmpty ?? true) })
        }
    }

    @Test func reasonChipsReadNaturally() {
        #expect(PlanReason.notHadIn(days: 21).text == "Haven't had it in 3 weeks")
        #expect(PlanReason.notHadIn(days: 12).text == "Haven't had it in 12 days")
        #expect(PlanReason.favorite(name: "Nora").text == "Nora's favorite")
        #expect(PlanReason.request(name: "Owen").text == "Owen's request")
        #expect(PlanReason.takeoutOnBusiestNight.text == "Takeout on the busiest night")
    }

    @Test func daysSinceCountsAcrossMonthsAndDaylightSaving() {
        let november = CalendarDay(year: 2026, month: 11, day: 3)
        #expect(november.days(since: CalendarDay(year: 2026, month: 10, day: 30)) == 4)
        #expect(CalendarDay(year: 2027, month: 3, day: 1).days(since: CalendarDay(year: 2027, month: 2, day: 28)) == 1)
        #expect(CalendarDay(year: 2028, month: 3, day: 1).days(since: CalendarDay(year: 2028, month: 2, day: 28)) == 2)
        #expect(CalendarDay(year: 2027, month: 1, day: 1).days(since: CalendarDay(year: 2026, month: 1, day: 1)) == 365)
    }

    // MARK: Shuffle

    @Test func shuffleChangesOnlyItsNight() {
        let meals = regulars(12)
        let planning = inputs(meals: meals, settings: settings(leftovers: 1, takeout: 1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            guard let index = draft.indices.first(where: { draft[$0].pick?.mealID != nil }) else { continue }
            let shuffled = BuildMyWeek.shuffle(night: draft[index].nightID, in: draft, inputs: planning, seed: seed + 1)
            for other in draft.indices where other != index { #expect(shuffled[other] == draft[other]) }
            #expect(shuffled[index].pick != draft[index].pick)
            let ids = mealIDs(shuffled).compactMap { $0 }
            #expect(Set(ids).count == ids.count, "Never a meal used elsewhere in the week")
            #expect(shuffled[index].reason != nil)
        }
    }

    @Test func shuffleLeavesKeptNightsAlone() {
        let meals = regulars(10)
        var nights = week()
        nights[0].locked = true
        nights[0].mealID = meals[0].id
        let planning = inputs(nights: nights, meals: meals)
        let draft = BuildMyWeek.draft(planning, seed: 1)
        #expect(BuildMyWeek.shuffle(night: nights[0].id, in: draft, inputs: planning, seed: 2) == draft)
    }

    @Test func shuffleKeepsTheNightWhenNothingElseFits() {
        let meals = regulars(7)
        let planning = inputs(meals: meals)
        let draft = BuildMyWeek.draft(planning, seed: 1)
        #expect(BuildMyWeek.shuffle(night: draft[3].nightID, in: draft, inputs: planning, seed: 2) == draft)
    }

    @Test func shuffleIsDeterministic() {
        let planning = inputs(meals: regulars(12))
        let draft = BuildMyWeek.draft(planning, seed: 1)
        let night = draft[2].nightID
        #expect(BuildMyWeek.shuffle(night: night, in: draft, inputs: planning, seed: 5)
            == BuildMyWeek.shuffle(night: night, in: draft, inputs: planning, seed: 5))
    }

    @Test func planningNightReadsAWeekNight() {
        let night = WeekNight(id: UUID(), date: start, effort: .rushed, dinnerTime: nil, mealID: nil, mealName: nil,
                              quickPick: .takeout, locked: true, attendance: [mom: true, dad: false])
        let planning = PlanningNight(night)
        #expect(planning.home == [mom])
        #expect(!planning.isFullAttendance)
        #expect(planning.quickPick == .takeout && planning.locked && planning.effort == .rushed)
    }
}
