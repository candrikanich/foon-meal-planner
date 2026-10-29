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

    private func trials(_ count: Int) -> [LibraryMeal] {
        (0..<count).map { LibraryMeal.fixture(name: "Trial \($0)", status: .trial) }
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

    /// The week as the store would save it once the draft is applied.
    private func saving(_ draft: [NightPlan], into planning: PlanningInputs) -> PlanningInputs {
        var saved = planning
        let picks = Dictionary(uniqueKeysWithValues: draft.map { ($0.nightID, $0.pick) })
        saved.nights = planning.nights.map { night in
            var night = night
            night.mealID = picks[night.id]??.mealID
            night.quickPick = picks[night.id]??.quickPick
            return night
        }
        return saved
    }

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

    @Test func theLibraryOrderDoesNotChangeTheDraft() {
        let meals = regulars(12) + [.fixture(name: "Chili", tags: [.leftovers])] + trials(2)
        let history = meals.prefix(13).enumerated().map { made($1, daysAgo: 15 + $0) }
        let forward = inputs(meals: meals, history: history, settings: settings(new: 1, leftovers: 1, takeout: 1))
        var reversed = forward
        reversed.meals.reverse()
        reversed.history.reverse()
        for seed in UInt64(0)..<20 {
            #expect(BuildMyWeek.draft(forward, seed: seed) == BuildMyWeek.draft(reversed, seed: seed))
        }
    }

    @Test func theGeneratorRepeatsItsSequenceForASeed() {
        var first = SeededGenerator(seed: 7), second = SeededGenerator(seed: 7), other = SeededGenerator(seed: 8)
        let sequence = (0..<5).map { _ in first.next() }
        #expect(sequence == (0..<5).map { _ in second.next() })
        #expect(sequence != (0..<5).map { _ in other.next() })
    }

    @Test func theDraftComesBackInDateOrder() {
        let planning = inputs(nights: Array(week().reversed()), meals: regulars(8))
        let dates = BuildMyWeek.draft(planning, seed: 1).map(\.date)
        #expect(dates == dates.sorted())
        #expect(dates.first == start)
    }

    @Test func todayDefaultsToTheFirstNight() {
        #expect(PlanningInputs(nights: Array(week().reversed()), meals: []).today == start)
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
        var planning = inputs(nights: nights, meals: meals)
        // Snoozed since it was planned: the redraw can't bring it back, so the night has to change.
        planning.snoozedMealIDs = [meals[0].id]
        let draft = BuildMyWeek.draft(planning, seed: 3)
        #expect(!draft[2].isKept)
        #expect(draft[2].pick?.mealID != nil && draft[2].pick != .meal(meals[0].id))
        #expect(!mealIDs(draft).contains(meals[0].id))
    }

    @Test func midWeekRebuildKeepsPastNightsAndCountsFromToday() {
        let roast = LibraryMeal.fixture(name: "Pot roast", tags: [.thawFirst])
        let known = regulars(2)
        var nights = week()
        nights[0].mealID = known[0].id
        nights[1].quickPick = .takeout
        var planning = inputs(nights: nights, meals: [roast, known[1]], history: [made(known[1], daysAgo: 30)],
                              settings: settings(takeout: 1))
        planning.today = start.adding(days: 3)
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft[0] == NightPlan(nightID: nights[0].id, date: nights[0].date, pick: .meal(known[0].id),
                                          reason: nil, isKept: true))
            #expect(draft[1].pick == .quickPick(.takeout) && draft[1].isKept)
            #expect(draft[2].pick == nil && draft[2].isKept && draft[2].reason == nil)
            #expect(draft.filter { $0.pick == .quickPick(.takeout) }.count == 1, "Past takeout counts")
            #expect(draft[3].pick != .meal(roast.id), "A 24-hour thaw can't make tonight")
            #expect(mealIDs(draft).contains(roast.id))
        }
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

    /// Pins the bypass: a request is the family asking out loud, so the filters don't apply.
    @Test func aRequestIsHonoredOnARushedNightAndWhenSomeoneHomeDislikesIt() {
        let meals = regulars(10)
        var planning = inputs(nights: week(efforts: [1: .rushed]), meals: meals)
        planning.notForMe = [meals[4].id: [nora: 1]]
        planning.requests = [DatedRequest(mealID: meals[3].id, date: start.adding(days: 1), requesterID: dad),
                             DatedRequest(mealID: meals[4].id, date: start.adding(days: 4), requesterID: mom)]
        let draft = BuildMyWeek.draft(planning, seed: 6)
        #expect(draft[1].pick == .meal(meals[3].id) && draft[1].reason == .request(name: "Dad"))
        #expect(draft[4].pick == .meal(meals[4].id) && draft[4].reason == .request(name: "Mom"))
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

    /// A planner brought back a dish two people voted out: it's active again, but only lands when both are away.
    @Test func aBroughtBackDishWithTwoDislikesOnlyLandsWhenBothAreAway() {
        let liver = LibraryMeal.fixture(name: "Liver")
        var planning = inputs(nights: week(away: [2: [nora], 4: [nora, dad]]), meals: [liver])
        planning.notForMe = [liver.id: [nora: 1, dad: 1]]
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.firstIndex { $0.pick == .meal(liver.id) } == 4)
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
            #expect(draft[0].pick == .meal(slowCooker.id), "An 8-hour slow cooker fits tonight")
        }
    }

    @Test func advancePrepNeedsEnoughHoursBeforeDinner() {
        let thaw = LibraryMeal.fixture(name: "Pot roast", tags: [.thawFirst])
        let overnight = LibraryMeal.fixture(name: "Kebabs", prepSteps: [PrepStep(step: "Marinate", leadHours: 12)])
        let twoDays = LibraryMeal.fixture(name: "Brisket", prepSteps: [PrepStep(step: "Brine", leadHours: 48)])
        let longThaw = LibraryMeal.fixture(name: "Turkey", tags: [.thawFirst],
                                           prepSteps: [PrepStep(step: "Thaw in the fridge", leadHours: 72)])
        let nights = Array(week().prefix(4))
        func firstNight(of meal: LibraryMeal) -> Int? {
            BuildMyWeek.draft(inputs(nights: nights, meals: [meal]), seed: 1).firstIndex { $0.pick == .meal(meal.id) }
        }
        #expect(firstNight(of: thaw) == 1, "Thaw first: 24 hours, so tomorrow, not tonight")
        #expect(firstNight(of: overnight) == 1)
        #expect(firstNight(of: twoDays) == 2)
        #expect(firstNight(of: longThaw) == 3, "A longer prep step beats the thaw-first default")
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

    @Test func theBigBatchTierRespectsTheNewDishBudget() {
        let trialChili = LibraryMeal.fixture(name: "Chili", tags: [.leftovers], status: .trial)
        let known = regulars(8)
        let planning = inputs(meals: [trialChili] + known, history: known.map { made($0, daysAgo: 30) },
                              settings: settings(new: 0, leftovers: 1))
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(!mealIDs(draft).contains(trialChili.id))
            #expect(draft.contains { $0.pick == .quickPick(.leftovers) && $0.reason == .leftoversNight })
        }
    }

    @Test func keptNightsCountTowardEverySetting() {
        let pinnedTrial = LibraryMeal.fixture(name: "Pinned trial", status: .trial)
        let otherTrials = trials(3)
        var nights = week()
        nights[0].locked = true
        nights[0].mealID = pinnedTrial.id
        nights[2].locked = true
        nights[2].quickPick = .takeout
        nights[4].effort = .event
        nights[4].quickPick = .leftovers
        let planning = inputs(nights: nights, meals: [pinnedTrial] + otherTrials + regulars(8),
                              settings: settings(new: 1, leftovers: 1, takeout: 1))
        let otherIDs = Set(otherTrials.map(\.id))
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.filter { $0.pick == .quickPick(.takeout) }.count == 1)
            #expect(draft.filter { $0.pick == .quickPick(.leftovers) }.count == 1)
            #expect(!draft.contains { $0.pick?.mealID.map { otherIDs.contains($0) } ?? false })
        }
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

    @Test func onATieTakeoutSkipsTheShoppingNight() {
        let planning = inputs(meals: regulars(8), settings: settings(takeout: 1))
        #expect(BuildMyWeek.draft(planning, seed: 1)[1].pick == .quickPick(.takeout))
    }

    @Test func newDishesLandOnFullAttendanceNights() {
        let trialDishes = trials(3)
        let neverMade = LibraryMeal.fixture(name: "Never made")
        let known = regulars(8)
        let away = Dictionary(uniqueKeysWithValues: [0, 1, 3, 4, 6].map { ($0, Set([nora])) })
        let planning = inputs(nights: week(away: away), meals: known + [neverMade] + trialDishes,
                              history: known.map { made($0, daysAgo: 30) }, settings: settings(new: 2))
        let trialIDs = Set(trialDishes.map(\.id))
        for seed in UInt64(0)..<50 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            let newNights = draft.indices.filter { draft[$0].pick?.mealID.map { trialIDs.contains($0) } ?? false }
            #expect(newNights == [2, 5])
            #expect(draft.filter { $0.reason == .somethingNew }.count == 2, "A never-made dish isn't new")
        }
    }

    /// Onboarding copies dishes the family already cooks: no history means "due", not "new".
    @Test func aFreshLibraryFillsTheWeekWithOrdinaryReasons() {
        let draft = BuildMyWeek.draft(inputs(meals: regulars(9), history: [], settings: settings(new: 1)), seed: 3)
        #expect(draft.allSatisfy { $0.pick?.mealID != nil && $0.reason == .dueForATurn })
    }

    @Test func trialDishesAreCappedUnlessNothingElseFits() {
        let trialDishes = trials(4)
        let known = regulars(8)
        let planning = inputs(meals: known + trialDishes, history: known.map { made($0, daysAgo: 30) },
                              settings: settings(new: 1))
        for seed in UInt64(0)..<30 {
            #expect(BuildMyWeek.draft(planning, seed: seed).filter { $0.reason == .somethingNew }.count == 1)
        }
        // Two known dishes for seven nights: trials fill what's left, still labeled as new.
        let twoKnown = Array(known.prefix(2))
        let short = inputs(meals: twoKnown + trialDishes, history: twoKnown.map { made($0, daysAgo: 30) },
                           settings: settings(new: 1))
        let draft = BuildMyWeek.draft(short, seed: 1)
        #expect(draft.filter { $0.reason == .somethingNew }.count == 4)
        #expect(draft.filter { $0.pick == nil }.count == 1)
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
        #expect(BuildMyWeek.draft(planning, seed: picks.first ?? 0)[0].reason == .usesWhatsOnHand)
    }

    @Test func everyFilledNightHasAReason() {
        let meals = [LibraryMeal.fixture(name: "Chili", tags: [.leftovers])] + regulars(10)
            + regulars(3, tags: [.quick]) + trials(1)
        let planning = inputs(nights: week(efforts: [2: .rushed, 5: .full]), meals: meals,
                              history: meals.filter { $0.status == .active }.map { made($0, daysAgo: 25) },
                              settings: settings(new: 1, leftovers: 1, takeout: 1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.allSatisfy { $0.reason != nil && !($0.reason?.text.isEmpty ?? true) })
        }
    }

    @Test func recencyIsCountedToEachNight() {
        let roast = LibraryMeal.fixture(name: "Pot roast")
        let planning = inputs(nights: Array(week().prefix(3)), meals: [roast], history: [made(roast, daysAgo: 12)])
        #expect(BuildMyWeek.draft(planning, seed: 1)[0].reason == .notHadIn(days: 12))
        var later = planning
        later.today = start.adding(days: 2)
        #expect(BuildMyWeek.draft(later, seed: 1)[2].reason == .notHadIn(days: 14))
    }

    @Test func aDishMadeOnTheNightItselfFallsThroughToTheNextReason() {
        let roast = LibraryMeal.fixture(name: "Pot roast")
        var noWindow = plain
        noWindow.repeatWindowDays = 0
        let planning = inputs(nights: Array(week().prefix(1)), meals: [roast], history: [made(roast, daysAgo: 0)],
                              settings: noWindow)
        #expect(BuildMyWeek.draft(planning, seed: 1)[0].reason == .dueForATurn)
    }

    @Test func reasonChipsReadNaturally() {
        #expect(PlanReason.notHadIn(days: 1).text == "Haven't had it since yesterday")
        #expect(PlanReason.notHadIn(days: 2).text == "Haven't had it in 2 days")
        #expect(PlanReason.notHadIn(days: 6).text == "Haven't had it in 6 days")
        #expect(PlanReason.notHadIn(days: 7).text == "Haven't had it in a week")
        #expect(PlanReason.notHadIn(days: 13).text == "Haven't had it in a week")
        #expect(PlanReason.notHadIn(days: 14).text == "Haven't had it in 2 weeks")
        #expect(PlanReason.notHadIn(days: 21).text == "Haven't had it in 3 weeks")
        #expect(PlanReason.dueForATurn.text == "Due for a turn")
        #expect(PlanReason.favorite(name: "Nora").text == "Nora's favorite")
        #expect(PlanReason.favorite(name: nil).text == "A family favorite")
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

    @Test func shuffleReplacesItsNightWithAMealNotInTheWeek() {
        let planning = inputs(meals: regulars(12), settings: settings(leftovers: 1, takeout: 1))
        for seed in UInt64(0)..<30 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            let saved = saving(draft, into: planning)
            guard let index = draft.indices.first(where: {
                draft[$0].pick?.mealID != nil && draft[$0].reason != .bigBatch
            }) else { continue }
            let shuffled = BuildMyWeek.shuffle(night: draft[index].nightID, inputs: saved, seed: seed + 1)
            let pick = shuffled?.pick?.mealID
            #expect(shuffled?.nightID == draft[index].nightID && shuffled?.isKept == false)
            #expect(pick != nil)
            #expect(!mealIDs(draft).contains(pick), "Never a meal already in the week, its own included")
            #expect(shuffled?.reason != nil)
        }
    }

    @Test func shuffleLeavesKeptNightsAlone() {
        let meals = regulars(10)
        var nights = week()
        nights[0].locked = true
        nights[0].mealID = meals[0].id
        nights[1].effort = .event
        nights[2].mealID = meals[2].id
        nights[4].mealID = meals[4].id
        var planning = inputs(nights: nights, meals: meals)
        planning.today = start.adding(days: 3)
        planning.requests = [DatedRequest(mealID: meals[4].id, date: start.adding(days: 4), requesterID: dad)]
        for index in [0, 1, 2, 4] {
            #expect(BuildMyWeek.shuffle(night: nights[index].id, inputs: planning, seed: 2) == nil)
        }
        #expect(BuildMyWeek.shuffle(night: nights[5].id, inputs: planning, seed: 2) != nil)
    }

    @Test func shuffleLeavesQuickPickNightsToSwap() {
        var nights = week()
        nights[3].quickPick = .takeout
        nights[4].quickPick = .leftovers
        let planning = inputs(nights: nights, meals: regulars(10))
        #expect(BuildMyWeek.shuffle(night: nights[3].id, inputs: planning, seed: 1) == nil)
        #expect(BuildMyWeek.shuffle(night: nights[4].id, inputs: planning, seed: 1) == nil)
    }

    @Test func shuffleKeepsTheNightWhenNothingElseFits() {
        let planning = inputs(meals: regulars(7))
        let saved = saving(BuildMyWeek.draft(planning, seed: 1), into: planning)
        #expect(BuildMyWeek.shuffle(night: saved.nights[3].id, inputs: saved, seed: 2) == nil)
    }

    @Test func shuffleKeepsATrialSlotTrial() {
        let trialDishes = trials(3)
        let known = regulars(10)
        var nights = week()
        nights[2].mealID = trialDishes[0].id
        let planning = inputs(nights: nights, meals: known + trialDishes,
                              history: known.map { made($0, daysAgo: 30) }, settings: settings(new: 1))
        for seed in UInt64(0)..<20 {
            let shuffled = BuildMyWeek.shuffle(night: nights[2].id, inputs: planning, seed: seed)
            #expect(trialDishes.dropFirst().contains { .meal($0.id) == shuffled?.pick })
            #expect(shuffled?.reason == .somethingNew)
        }
    }

    @Test func shuffleDoesNotAddATrialPastTheBudget() {
        let trialDishes = trials(2)
        let known = regulars(2)
        var nights = week()
        nights[1].mealID = trialDishes[0].id
        nights[3].mealID = known[0].id
        let planning = inputs(nights: nights, meals: known + trialDishes,
                              history: known.map { made($0, daysAgo: 30) }, settings: settings(new: 1))
        for seed in UInt64(0)..<20 {
            #expect(BuildMyWeek.shuffle(night: nights[3].id, inputs: planning, seed: seed)?.pick == .meal(known[1].id))
        }
        var oneKnown = planning
        oneKnown.meals = [known[0]] + trialDishes
        #expect(BuildMyWeek.shuffle(night: nights[3].id, inputs: oneKnown, seed: 1) == nil)
    }

    @Test func shuffleKeepsABigBatchFeedingLeftovers() {
        let chili = LibraryMeal.fixture(name: "Chili", tags: [.leftovers])
        let stew = LibraryMeal.fixture(name: "Stew", tags: [.leftovers])
        var nights = week()
        nights[2].mealID = chili.id
        nights[3].quickPick = .leftovers
        let planning = inputs(nights: nights, meals: [chili, stew] + regulars(8))
        for seed in UInt64(0)..<20 {
            let shuffled = BuildMyWeek.shuffle(night: nights[2].id, inputs: planning, seed: seed)
            #expect(shuffled?.pick == .meal(stew.id) && shuffled?.reason == .bigBatch)
        }
        var noOtherBatch = planning
        noOtherBatch.meals = [chili] + regulars(8)
        #expect(BuildMyWeek.shuffle(night: nights[2].id, inputs: noOtherBatch, seed: 1) == nil)
    }

    @Test func shuffleFillsAnEmptyNight() {
        let planning = inputs(meals: regulars(10))
        #expect(BuildMyWeek.shuffle(night: planning.nights[3].id, inputs: planning, seed: 4)?.pick?.mealID != nil)
    }

    @Test func shuffleIsDeterministic() {
        let planning = inputs(meals: regulars(12))
        let saved = saving(BuildMyWeek.draft(planning, seed: 1), into: planning)
        let night = saved.nights[2].id
        #expect(BuildMyWeek.shuffle(night: night, inputs: saved, seed: 5)
            == BuildMyWeek.shuffle(night: night, inputs: saved, seed: 5))
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
