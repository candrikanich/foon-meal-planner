import Foundation
import Testing
@testable import Foon

/// Seasonal weighting and variety (#54). Dishes here are never made unless a test says so, so recency is equal and
/// only the weight under test moves the share. Shares come from `seeds`, with bounds well clear of the expected value.
struct SeasonalVarietyTests {
    private let july = CalendarDay(year: 2026, month: 7, day: 5)
    private let january = CalendarDay(year: 2027, month: 1, day: 3)
    /// Neither summer nor winter.
    private let april = CalendarDay(year: 2026, month: 4, day: 5)
    private let nora = UUID(), dad = UUID()
    private let seeds = UInt64(0)..<400
    /// An even split of `seeds` is 200; a doubled dish expects 267.
    private let aboveEven = 233

    private var plain: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.takeoutNights = 0
        return settings
    }

    private func nights(from start: CalendarDay, count: Int = 7) -> [PlanningNight] {
        (0..<count).map { offset in
            PlanningNight(id: UUID(), date: start.adding(days: offset), attendance: [nora: true, dad: true])
        }
    }

    private func planning(_ nights: [PlanningNight], _ meals: [LibraryMeal], today: CalendarDay? = nil) -> PlanningInputs {
        PlanningInputs(nights: nights, meals: meals, settings: plain, today: today)
    }

    /// How many seeds put `meal` on the only open night.
    private func wins(_ meal: LibraryMeal, against other: LibraryMeal, on day: CalendarDay, today: CalendarDay? = nil) -> Int {
        let inputs = planning(nights(from: day, count: 1), [meal, other], today: today)
        return seeds.filter { BuildMyWeek.draft(inputs, seed: $0)[0].pick == .meal(meal.id) }.count
    }

    private func plainDish() -> LibraryMeal { .fixture(name: "Meatless Monday") }

    private func mealIDs(_ draft: [NightPlan]) -> [UUID?] { draft.map(\.pick?.mealID) }

    // MARK: Season

    @Test(arguments: [
        (2026, 5, 31, nil), (2026, 6, 1, Season.summer), (2026, 8, 31, .summer), (2026, 9, 1, nil),
        (2026, 11, 30, nil), (2026, 12, 1, .winter), (2027, 1, 15, .winter), (2028, 2, 29, .winter), (2028, 3, 1, nil),
    ] as [(Int, Int, Int, Season?)])
    func theSeasonComesFromTheDate(year: Int, month: Int, day: Int, season: Season?) {
        #expect(CalendarDay(year: year, month: month, day: day).season == season)
    }

    @Test func grillAndColdDishesRiseInSummer() {
        let grill = LibraryMeal.fixture(name: "Dad's special", tags: [.grill])
        let cold = LibraryMeal.fixture(name: "Chicken salad")
        #expect(wins(grill, against: plainDish(), on: july) > aboveEven)
        #expect(wins(cold, against: plainDish(), on: july) > aboveEven)
    }

    @Test func soupsAndSlowCookerRiseInWinter() {
        let soup = LibraryMeal.fixture(name: "Potato soup")
        let stew = LibraryMeal.fixture(name: "Beef stew")
        let slow = LibraryMeal.fixture(name: "Dad's special", tags: [.slowCooker])
        #expect(wins(soup, against: plainDish(), on: january) > aboveEven)
        #expect(wins(stew, against: plainDish(), on: january) > aboveEven)
        #expect(wins(slow, against: plainDish(), on: january) > aboveEven)
    }

    @Test func dishesOutOfSeasonGetNoBoost() {
        let grill = LibraryMeal.fixture(name: "Dad's special", tags: [.grill])
        let soup = LibraryMeal.fixture(name: "Potato soup")
        #expect(wins(grill, against: plainDish(), on: january) < aboveEven)
        #expect(wins(soup, against: plainDish(), on: july) < aboveEven)
        #expect(wins(grill, against: plainDish(), on: april) < aboveEven)
        #expect(wins(soup, against: plainDish(), on: april) < aboveEven)
    }

    @Test func aDishCountsAsInSeasonOnceHoweverManyWaysItFits() {
        let both = LibraryMeal.fixture(name: "Grilled chicken salad", tags: [.grill])
        #expect(wins(both, against: plainDish(), on: july) < 300, "Doubled expects 267; stacked would expect 320")
    }

    /// Sunday's build for a week that crosses into June: each night is judged by its own date, not by today.
    @Test func eachNightIsJudgedByItsOwnDate() {
        let grill = LibraryMeal.fixture(name: "Dad's special", tags: [.grill])
        let today = CalendarDay(year: 2026, month: 5, day: 30)
        #expect(wins(grill, against: plainDish(), on: CalendarDay(year: 2026, month: 5, day: 31), today: today) < aboveEven)
        #expect(wins(grill, against: plainDish(), on: CalendarDay(year: 2026, month: 6, day: 1), today: today) > aboveEven)
    }

    // MARK: Weighting only biases the draw

    @Test func theBoostNeverOverridesAFilter() {
        let disliked = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let snoozed = LibraryMeal.fixture(name: "Brats", tags: [.grill])
        let recent = LibraryMeal.fixture(name: "Kebabs", tags: [.grill])
        let slow = LibraryMeal.fixture(name: "Steak", tags: [.grill])
        let retired = LibraryMeal.fixture(name: "Hot dogs", tags: [.grill], status: .retired)
        let safe = (0..<4).map { LibraryMeal.fixture(name: "Plain \($0)") }
        var inputs = planning(nights(from: july, count: 2), [disliked, snoozed, recent, slow, retired] + safe)
        inputs.nights[0].effort = .rushed
        inputs.notForMe = [disliked.id: [nora: 1]]
        inputs.snoozedMealIDs = [snoozed.id]
        inputs.history = [MealHistory(mealID: recent.id, timesMade: 3, lastMade: july)]
        for seed in UInt64(0)..<100 {
            let ids = mealIDs(BuildMyWeek.draft(inputs, seed: seed))
            for meal in [disliked, snoozed, recent, retired] {
                #expect(!ids.contains(meal.id), "\(meal.name) didn't pass the filters")
            }
            #expect(ids[0] == nil, "A rushed night takes only quick dishes, in season or not")
        }
    }

    @Test func theBoostNeverMovesAKeptNightOrATradition() {
        let soup = LibraryMeal.fixture(name: "Potato soup")
        let grills = (0..<8).map { LibraryMeal.fixture(name: "Grill \($0)", tags: [.grill]) }
        var week = nights(from: july)
        week[1].locked = true
        week[1].mealID = soup.id
        var inputs = planning(week, [soup] + grills)
        let tuesday = week[2].date.isoWeekday
        inputs.traditions = [Tradition(weekday: tuesday, pick: .quickPick(.takeout), name: "Takeout Tuesday")]
        inputs.requests = [DatedRequest(mealID: grills[0].id, date: week[3].date, requesterID: dad)]
        for seed in UInt64(0)..<50 {
            let draft = BuildMyWeek.draft(inputs, seed: seed)
            #expect(draft[1].pick == .meal(soup.id) && draft[1].isKept)
            #expect(draft[2].pick == .quickPick(.takeout))
            #expect(draft[3].pick == .meal(grills[0].id))
        }
    }

    // MARK: Determinism

    /// Nothing in season, nothing repeating: every factor is 1, so the month can't change a single pick.
    @Test func aLibraryWithNothingSeasonalDrawsTheSameInEverySeason() {
        let meals = (0..<12).map { LibraryMeal.fixture(name: "Dish \($0)") }
        for seed in UInt64(0)..<50 {
            let spring = mealIDs(BuildMyWeek.draft(planning(nights(from: april), meals), seed: seed))
            #expect(mealIDs(BuildMyWeek.draft(planning(nights(from: july), meals), seed: seed)) == spring)
            #expect(mealIDs(BuildMyWeek.draft(planning(nights(from: january), meals), seed: seed)) == spring)
        }
    }

    /// Fixed ids, so the draw order is the same on every run: these weeks are exact, not a share.
    private var pinnedLibrary: [LibraryMeal] {
        ["Burgers", "Chicken salad", "Potato soup", "Beef stew", "Baked ziti", "Lasagna", "Chicken Alfredo", "Pancakes",
         "Tacos", "Pierogies"].enumerated().map { index, name in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID()
            return .fixture(id: id, name: name, tags: name == "Burgers" ? [.grill] : [])
        }
    }

    private func pinnedNames(from start: CalendarDay, seed: UInt64) -> [String?] {
        let library = pinnedLibrary
        let draft = BuildMyWeek.draft(planning(nights(from: start), library), seed: seed)
        return draft.map { plan in library.first { $0.id == plan.pick?.mealID }?.name }
    }

    @Test func aPinnedSeedGivesTheSameExactWeek() {
        #expect(pinnedNames(from: july, seed: 42)
            == ["Chicken Alfredo", "Beef stew", "Pancakes", "Pierogies", "Tacos", "Burgers", "Chicken salad"])
        #expect(pinnedNames(from: january, seed: 42)
            == ["Chicken Alfredo", "Beef stew", "Pancakes", "Pierogies", "Tacos", "Burgers", "Potato soup"],
                "The same seed, and the season moves a pick")
    }

    @Test func theLibraryOrderStillDoesNotChangeASeasonalDraft() {
        let meals = pinnedLibrary
        for seed in UInt64(0)..<30 {
            let week = nights(from: january)
            #expect(BuildMyWeek.draft(planning(week, meals), seed: seed)
                == BuildMyWeek.draft(planning(week, meals.reversed()), seed: seed))
        }
    }

    // MARK: Always a full week

    @Test func aSeasonWithNothingMatchingStillFillsTheWeek() {
        let soups = (0..<7).map { LibraryMeal.fixture(name: "Soup \($0)") }
        let grills = (0..<7).map { LibraryMeal.fixture(name: "Grill \($0)", tags: [.grill]) }
        let plainDishes = (0..<7).map { LibraryMeal.fixture(name: "Dish \($0)") }
        for (start, meals) in [(july, soups), (january, grills), (july, plainDishes), (january, plainDishes)] {
            let draft = BuildMyWeek.draft(planning(nights(from: start), meals), seed: 7)
            #expect(draft.allSatisfy { $0.pick?.mealID != nil && $0.reason == .dueForATurn })
        }
    }

    @Test func aLibraryOfOneCategoryStillFillsTheWeek() {
        let pasta = (0..<7).map { LibraryMeal.fixture(name: "Spaghetti \($0)") }
        for seed in UInt64(0)..<20 {
            let draft = BuildMyWeek.draft(planning(nights(from: july), pasta), seed: seed)
            #expect(Set(mealIDs(draft).compactMap { $0 }).count == 7, "The variety nudge only leans; it never empties a night")
        }
    }

    // MARK: Variety in the draw

    @Test func aCategoryAlreadyInTheWeekIsDrawnLessOften() {
        let ziti = LibraryMeal.fixture(name: "Baked ziti"), lasagna = LibraryMeal.fixture(name: "Lasagna")
        let alfredo = LibraryMeal.fixture(name: "Fettuccine"), other = plainDish()
        func alfredoWins(pinned: [LibraryMeal]) -> Int {
            var week = nights(from: april, count: pinned.count + 1)
            for (index, meal) in pinned.enumerated() {
                week[index].locked = true
                week[index].mealID = meal.id
            }
            let inputs = planning(week, pinned + [alfredo, other])
            return seeds.filter { BuildMyWeek.draft(inputs, seed: $0)[pinned.count].pick == .meal(alfredo.id) }.count
        }
        #expect(alfredoWins(pinned: []) > 160, "No pasta yet: an even split, 200")
        #expect((100...170).contains(alfredoWins(pinned: [ziti])), "One pasta in the week: 1 in 3, 133")
        #expect(alfredoWins(pinned: [ziti, lasagna]) < 110, "Two: 1 in 5, 80")
    }

    @Test func aRepeatCountsOnceHoweverManyCategoriesItShares() {
        let pinned = LibraryMeal.fixture(name: "Chicken Alfredo")
        let shares = LibraryMeal.fixture(name: "Chicken carbonara"), other = plainDish()
        var week = nights(from: april, count: 2)
        week[0].locked = true
        week[0].mealID = pinned.id
        let inputs = planning(week, [pinned, shares, other])
        let picks = seeds.filter { BuildMyWeek.draft(inputs, seed: $0)[1].pick == .meal(shares.id) }.count
        #expect(picks > 100, "Halved once (expects 133), not once per shared category (expects 80)")
    }

    @Test func aFullWeekLeansAwayFromRepeatingACategory() {
        let pasta = (0..<7).map { LibraryMeal.fixture(name: "Spaghetti \($0)") }
        let others = (0..<7).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let inputs = planning(nights(from: april), pasta + others)
        let pastaIDs = Set(pasta.map(\.id))
        let total = (UInt64(0)..<200).map { seed in
            mealIDs(BuildMyWeek.draft(inputs, seed: seed)).compactMap { $0 }.filter(pastaIDs.contains).count
        }.reduce(0, +)
        #expect(Double(total) / 200 < 3, "Expects about 2.5; without the lean a week averages 3.5 pasta nights")
    }

    @Test func aSummerOfGrillingDoesNotTakeOverTheWeek() {
        let grills = (0..<7).map { LibraryMeal.fixture(name: "Burgers \($0)", tags: [.grill]) }
        let others = (0..<7).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let inputs = planning(nights(from: july), grills + others)
        let grillIDs = Set(grills.map(\.id))
        let total = (UInt64(0)..<200).map { seed in
            mealIDs(BuildMyWeek.draft(inputs, seed: seed)).compactMap { $0 }.filter(grillIDs.contains).count
        }.reduce(0, +)
        #expect(Double(total) / 200 < 3.5, "The boost is real, but repeats pull it back")
        #expect(Double(total) / 200 > 2, "It still shows up")
    }

    @Test func shuffleAndSwapSuggestionsLeanTheSameWay() {
        let grill = LibraryMeal.fixture(name: "Dad's special", tags: [.grill]), other = plainDish()
        let night = nights(from: july, count: 1)
        let inputs = planning(night, [grill, other])
        let shuffled = seeds.filter {
            BuildMyWeek.shuffle(night: night[0].id, inputs: inputs, seed: $0)?.pick == .meal(grill.id)
        }.count
        let suggested = seeds.filter {
            BuildMyWeek.suggestions(night: night[0].id, inputs: inputs, seed: $0, count: 1).first?.mealID == grill.id
        }.count
        #expect(shuffled > aboveEven)
        #expect(suggested > aboveEven)
    }

    // MARK: Telling dishes apart by name

    @Test(arguments: [
        ("Pasta with sauce and meatballs", [DishCategory.pasta, .beef]),
        ("Sausage and noodles", [.pasta, .pork]),
        ("Homemade mac and cheese", [.pasta]),
        ("Box mac and cheese", [.pasta]),
        ("Baked ziti", [.pasta]),
        ("Lasagna", [.pasta]),
        ("Chicken Alfredo", [.pasta, .chicken]),
        ("Tacos", [.texMex]),
        ("Breakfast burritos", [.texMex, .breakfast]),
        ("Burgers", [.grilling, .beef]),
        ("Hot dogs", [.grilling]),
        ("Steak night", [.grilling, .beef]),
        ("Tomato soup and grilled cheese", [.soup, .sandwiches]),
        ("Chicken noodle soup", [.soup, .chicken]),
        ("White chicken chili", [.soup, .chicken]),
        ("Vegetable or minestrone soup", [.soup]),
        ("BLTs", [.sandwiches]),
        ("Italian subs or hoagies", [.sandwiches]),
        ("Shepherd's pie", [.beef]),
        ("Ham and scalloped potatoes", [.pork]),
        ("Fish sticks and fries", [.seafood]),
        ("Pancakes", [.breakfast]),
        ("Freezer pizza", [.pizza]),
        ("Pierogies", []),
        ("Eggplant parm", []),
        ("Hamburger helper", [.grilling, .beef]),
        ("Chili dogs", [.grilling]),
        ("Cold cucumber soup", []),
    ] as [(String, Set<DishCategory>)])
    func aDishNameSaysWhatItIs(name: String, categories: Set<DishCategory>) {
        #expect(DishTraits(name: name).categories == categories)
    }

    @Test(arguments: [
        ("Chicken salad sandwiches", true), ("Italian subs or hoagies", true), ("Chicken Caesar wraps", true),
        ("BLTs", true), ("Gazpacho", true), ("Cold cucumber soup", true),
        ("Potato soup", false), ("Saladless Sunday", false), ("Chicken stir-fry", false),
    ])
    func aDishNameSaysWhetherItsCold(name: String, isCold: Bool) {
        #expect(DishTraits(name: name).isCold == isCold)
    }

    // MARK: The nudge

    @Test func threeOfACategoryInAWeekMakesANudge() {
        let nudges = VarietyNudge.nudges(mealNames: ["Baked ziti", "Lasagna", "Pasta primavera", "Tacos"])
        #expect(nudges == [VarietyNudge(category: .pasta, count: 3)])
        #expect(nudges.first?.text(nextWeek: false) == "Pasta 3 times this week")
        #expect(nudges.first?.text(nextWeek: true) == "Pasta 3 times next week")
    }

    @Test func twoOfACategoryIsNotANudge() {
        #expect(VarietyNudge.nudges(mealNames: ["Baked ziti", "Lasagna", "Tacos", "Pancakes"]).isEmpty)
        #expect(VarietyNudge.nudges(mealNames: []).isEmpty)
    }

    @Test func theMostRepeatedCategoryComesFirstAndATieHasAFixedOrder() {
        let names = ["Baked ziti", "Lasagna", "Spaghetti", "Tacos", "Burritos", "Enchiladas", "Nachos"]
        #expect(VarietyNudge.nudges(mealNames: names) == [VarietyNudge(category: .texMex, count: 4),
                                                         VarietyNudge(category: .pasta, count: 3)])
        let tied = ["Baked ziti", "Lasagna", "Spaghetti", "Tacos", "Burritos", "Enchiladas"]
        #expect(VarietyNudge.nudges(mealNames: tied).map(\.category) == [.pasta, .texMex])
        #expect(VarietyNudge.nudges(mealNames: tied.reversed()).map(\.category) == [.pasta, .texMex])
    }

    @Test(arguments: DishCategory.allCases)
    func everyCategoryHasATitle(category: DishCategory) {
        #expect(!category.title.isEmpty)
    }
}
