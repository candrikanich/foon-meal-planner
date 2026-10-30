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

    /// How many of `dishes` an average week holds, over 200 seeds.
    private func averageNights(of dishes: [LibraryMeal], in library: [LibraryMeal], from start: CalendarDay) -> Double {
        let ids = Set(dishes.map(\.id))
        let inputs = planning(nights(from: start), library)
        let total = (UInt64(0)..<200).map { seed in
            mealIDs(BuildMyWeek.draft(inputs, seed: seed)).compactMap { $0 }.filter(ids.contains).count
        }.reduce(0, +)
        return Double(total) / 200
    }

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
        let summer = averageNights(of: grills, in: grills + others, from: july)
        #expect(summer < 3.5, "The boost is real, but repeats pull it back")
        #expect(summer > averageNights(of: grills, in: grills + others, from: april) + 0.25,
                "The same library in spring, no boost: it still shows up")
    }

    /// The boost reads the tag, so the repeats have to as well, or a dish whose name doesn't say grill runs away.
    @Test func aGrillTaggedDishWithAnUnreadableNameIsDampedLikeAnyOther() {
        let grills = ["BBQ ribs", "Carne asada", "Dad's special", "Ribs", "Corn on the cob", "Tri-tip", "Pork chops"]
            .map { LibraryMeal.fixture(name: $0, tags: [.grill]) }
        let others = (0..<7).map { LibraryMeal.fixture(name: "Dish \($0)") }
        #expect(averageNights(of: grills, in: grills + others, from: july) < 3.5, "Undamped, this is above 4")
        #expect(DishTraits(name: "BBQ ribs", tags: [.grill]).categories == [.grilling])
        #expect(DishTraits(name: "BBQ ribs").categories.isEmpty)
    }

    /// Kept nights and traditions land whatever the odds say, and still count against what's drawn after them.
    @Test func keptNightsAndTraditionsIgnoreTheVarietyFactorButCountTowardIt() {
        let ziti = LibraryMeal.fixture(name: "Baked ziti"), lasagna = LibraryMeal.fixture(name: "Lasagna")
        let spaghetti = LibraryMeal.fixture(name: "Spaghetti"), fettuccine = LibraryMeal.fixture(name: "Fettuccine")
        let other = plainDish()
        var week = nights(from: april, count: 4)
        week[0].locked = true
        week[0].mealID = ziti.id
        var inputs = planning(week, [ziti, lasagna, spaghetti, fettuccine, other])
        inputs.traditions = [Tradition(weekday: week[1].date.isoWeekday, pick: .meal(lasagna.id), name: "Lasagna night")]
        inputs.requests = [DatedRequest(mealID: spaghetti.id, date: week[2].date, requesterID: dad)]
        let picks = seeds.map { BuildMyWeek.draft(inputs, seed: $0) }
        for draft in picks {
            #expect(draft[0].pick == .meal(ziti.id))
            #expect(draft[1].pick == .meal(lasagna.id))
            #expect(draft[2].pick == .meal(spaghetti.id))
        }
        let fettuccineWins = picks.filter { $0[3].pick == .meal(fettuccine.id) }.count
        #expect(fettuccineWins < 80, "Three pasta nights already: 1 in 9, 44")
    }

    // MARK: Variety in Shuffle and Swap

    /// Shuffling away the only pasta of the week: that dish is leaving, so it isn't a repeat.
    @Test func shuffleDoesNotCountTheDishItIsReplacing() {
        let ziti = LibraryMeal.fixture(name: "Baked ziti"), lasagna = LibraryMeal.fixture(name: "Lasagna")
        let fettuccine = LibraryMeal.fixture(name: "Fettuccine"), other = plainDish()
        var alone = nights(from: april, count: 1)
        alone[0].mealID = ziti.id
        let aloneInputs = planning(alone, [ziti, fettuccine, other])
        let evenSplit = seeds.filter {
            BuildMyWeek.shuffle(night: alone[0].id, inputs: aloneInputs, seed: $0)?.pick == .meal(fettuccine.id)
        }.count
        #expect(evenSplit > 165, "Nothing else in the week: an even split, 200")

        var withAnother = nights(from: april, count: 2)
        withAnother[0].mealID = ziti.id
        withAnother[1].locked = true
        withAnother[1].mealID = lasagna.id
        let anotherInputs = planning(withAnother, [ziti, lasagna, fettuccine, other])
        let oneRepeat = seeds.filter {
            BuildMyWeek.shuffle(night: withAnother[0].id, inputs: anotherInputs, seed: $0)?.pick == .meal(fettuccine.id)
        }.count
        #expect(oneRepeat < 165, "Another pasta stays in the week: 1 in 3, 133")
    }

    @Test func swapSuggestionsDoNotCountTheDishBeingSwappedOut() {
        let ziti = LibraryMeal.fixture(name: "Baked ziti")
        let fettuccine = LibraryMeal.fixture(name: "Fettuccine"), other = plainDish()
        var night = nights(from: april, count: 1)
        night[0].mealID = ziti.id
        let inputs = planning(night, [ziti, fettuccine, other])
        let picks = seeds.filter {
            BuildMyWeek.suggestions(night: night[0].id, inputs: inputs, seed: $0, count: 1).first?.mealID == fettuccine.id
        }.count
        #expect(picks > 165, "An even split, 200")
    }

    /// Three suggestions are three choices, so each leans away from the ones already offered.
    @Test func swapSuggestionsLeanAwayFromEachOther() {
        let first = LibraryMeal.fixture(name: "Baked ziti"), second = LibraryMeal.fixture(name: "Lasagna")
        let night = nights(from: april, count: 1)
        let inputs = planning(night, [first, second, plainDish()])
        let bothPasta = seeds.filter { seed in
            Set(BuildMyWeek.suggestions(night: night[0].id, inputs: inputs, seed: seed, count: 2).map(\.mealID))
                == [first.id, second.id]
        }.count
        #expect(bothPasta < 115, "Expects 2 in 9, 89; counting nothing it would be 1 in 3, 133")
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

    /// Every dish in docs/starter-pack.md: what each one counts as, and whether it reads as cold.
    private static let starterDishes: [(name: String, categories: Set<DishCategory>, isCold: Bool)] = [
        ("Pasta with sauce and meatballs", [.pasta, .beef], false),
        ("Sausage and noodles", [.pasta, .pork], false),
        ("Homemade mac and cheese", [.pasta], false),
        ("Baked ziti", [.pasta], false),
        ("Lasagna", [.pasta], false),
        ("Chicken Alfredo", [.pasta, .chicken], false),
        ("Pasta primavera", [.pasta], false),
        ("Tacos", [.texMex], false),
        ("Salsa chicken over rice", [.texMex, .chicken], false),
        ("Burrito bowls", [.texMex], false),
        ("Quesadillas", [.texMex], false),
        ("Enchiladas", [.texMex], false),
        ("Chili", [.soup], false),
        ("Shrimp tacos", [.texMex, .seafood], false),
        ("Burgers", [.grilling, .beef], false),
        ("Hot dogs", [.grilling], false),
        ("Brats", [.grilling, .pork], false),
        ("Grilled chicken", [.grilling, .chicken], false),
        ("Kebabs", [.grilling], false),
        ("Steak night", [.grilling, .beef], false),
        ("Sloppy joes", [.sandwiches, .beef], false),
        ("BLTs", [.sandwiches], true),
        ("Italian subs or hoagies", [.sandwiches], true),
        ("French dip", [.sandwiches, .beef], false),
        ("Chicken salad sandwiches", [.sandwiches, .chicken], true),
        ("Paninis", [.sandwiches], false),
        ("BBQ pulled pork sandwiches", [.sandwiches, .pork], false),
        ("Chicken Caesar wraps", [.sandwiches, .chicken], true),
        ("Tomato soup and grilled cheese", [.soup, .sandwiches], false),
        ("Chicken noodle soup", [.soup, .chicken], false),
        ("Beef stew", [.soup, .beef], false),
        ("Potato soup", [.soup], false),
        ("Broccoli cheddar soup", [.soup], false),
        ("Vegetable or minestrone soup", [.soup], false),
        ("White chicken chili", [.soup, .chicken], false),
        ("Sheet-pan chicken and veggies", [.chicken], false),
        ("Chicken stir-fry", [.chicken], false),
        ("Baked chicken thighs and potatoes", [.chicken], false),
        ("Chicken parmesan", [.chicken], false),
        ("Rotisserie chicken night", [.chicken], false),
        ("Pork chops and applesauce", [.pork], false),
        ("Pork tenderloin", [.pork], false),
        ("Pulled pork", [.pork], false),
        ("Ham and scalloped potatoes", [.pork], false),
        ("Pot roast", [.beef], false),
        ("Meatloaf and mashed potatoes", [.beef], false),
        ("Beef stir-fry", [.beef], false),
        ("Shepherd's pie", [.beef], false),
        ("Baked salmon and rice", [.seafood], false),
        ("Baked tilapia", [.seafood], false),
        ("Crab cakes", [.seafood], false),
        ("Seared scallops", [.seafood], false),
        ("Fish and chips night", [.seafood], false),
        ("Egg sandwiches with bacon", [.sandwiches, .breakfast], false),
        ("Pancakes", [.breakfast], false),
        ("Waffles", [.breakfast], false),
        ("Breakfast burritos", [.texMex, .breakfast], false),
        ("French toast", [.breakfast], false),
        ("Make-your-own night", [], false),
        ("Baked potato bar", [], false),
        ("Nacho bar", [.texMex], false),
        ("Homemade pizza night", [.pizza], false),
        ("Rice bowl bar", [], false),
        ("Freezer pizza", [.pizza], false),
        ("Pierogies", [], false),
        ("Box mac and cheese", [.pasta], false),
        ("Frozen dumplings or potstickers", [], false),
        ("Fish sticks and fries", [.seafood], false),
        ("Chicken nuggets and tots", [.chicken], false),
    ]

    @Test func everyStarterDishReadsAsWhatItIs() {
        #expect(Self.starterDishes.count == 69)
        for dish in Self.starterDishes {
            let traits = DishTraits(name: dish.name)
            #expect(traits.categories == dish.categories, "\(dish.name)")
            #expect(traits.isCold == dish.isCold, "\(dish.name)")
        }
    }

    @Test(arguments: [
        ("Eggplant parm", []),
        ("Chili dogs", [.grilling]),
        ("Cold cucumber soup", []),
        // A lookalike rules out only the words it covers, not the rest of the name.
        ("Sweet chili chicken soup", [DishCategory.soup, .chicken]),
        ("Chili lime chicken soup", [.soup, .chicken]),
        ("Grilled cheese and burgers", [.sandwiches, .grilling, .beef]),
        // Names that look like a category and aren't. Misses are fine; these are just common.
        ("Hamburger helper", [.beef]),
        ("Salisbury steak", [.beef]),
        ("Chicken fried steak", [.beef]),
        ("Spaghetti squash", []),
        ("Zucchini noodles", []),
        ("Thai chili chicken", [.chicken]),
        ("Honey chili shrimp", [.seafood]),
        ("Soup dumplings", []),
    ] as [(String, Set<DishCategory>)])
    func aDishNameSaysWhatItIs(name: String, categories: Set<DishCategory>) {
        #expect(DishTraits(name: name).categories == categories)
    }

    @Test(arguments: [
        ("Gazpacho", true), ("Cold cucumber soup", true), ("Chilled pea soup", true), ("Chicken salad", true),
        ("Potato soup", false), ("Saladless Sunday", false), ("Chicken stir-fry", false),
    ])
    func aDishNameSaysWhetherItsCold(name: String, isCold: Bool) {
        #expect(DishTraits(name: name).isCold == isCold)
    }

    /// Only the name saying cold takes a soup out of winter. A salad or sandwich beside it doesn't, and the hot bowl
    /// keeps the dish out of summer's cold lean.
    @Test(arguments: [
        ("Soup and salad", Season.winter), ("Chili and salad", .winter), ("Tomato soup and BLT", .winter),
        ("Soup and a wrap", .winter), ("Cold night chili", .winter), ("Cold cucumber soup", .summer),
        ("Chilled pea soup", .summer), ("Gazpacho", .summer),
    ] as [(String, Season)])
    func aSoupWithACoolThingBesideItIsStillSoup(name: String, season: Season) {
        let traits = DishTraits(name: name)
        #expect(traits.isInSeason(season))
        #expect(!traits.isInSeason(season == .winter ? .summer : .winter))
    }

    // MARK: The nudge

    private func layout(_ names: [String?], today: Int = 0, locked: Set<Int> = [], events: Set<Int> = []) -> WeekLayout {
        let nights = names.enumerated().map { index, name in
            WeekNight(id: UUID(), date: april.adding(days: index), effort: events.contains(index) ? .event : .normal,
                      dinnerTime: nil, mealID: name == nil ? nil : UUID(), mealName: name, quickPick: nil,
                      locked: locked.contains(index), attendance: [:])
        }
        return WeekLayout(nights: nights, today: april.adding(days: today))
    }

    private let threePasta: [String?] = ["Baked ziti", "Lasagna", "Pasta primavera", "Tacos"]

    @Test func threeOfACategoryInAWeekMakesANudge() {
        let nudge = VarietyNudge.nudge(mealNames: ["Baked ziti", "Lasagna", "Pasta primavera", "Tacos"])
        #expect(nudge == VarietyNudge(category: .pasta, count: 3))
        #expect(nudge?.text(nextWeek: false) == "Pasta 3 times this week")
        #expect(nudge?.text(nextWeek: true) == "Pasta 3 times next week")
    }

    @Test func twoOfACategoryIsNotANudge() {
        #expect(VarietyNudge.nudge(mealNames: ["Baked ziti", "Lasagna", "Tacos", "Pancakes"]) == nil)
        #expect(VarietyNudge.nudge(mealNames: []) == nil)
    }

    @Test func onlyTheMostRepeatedCategoryIsNamedAndATieHasAFixedOrder() {
        let names = ["Baked ziti", "Lasagna", "Spaghetti", "Tacos", "Burritos", "Enchiladas", "Nachos"]
        #expect(VarietyNudge.nudge(mealNames: names) == VarietyNudge(category: .texMex, count: 4))
        let tied = ["Baked ziti", "Lasagna", "Spaghetti", "Tacos", "Burritos", "Enchiladas"]
        #expect(VarietyNudge.nudge(mealNames: tied)?.category == .pasta)
        #expect(VarietyNudge.nudge(mealNames: tied.reversed())?.category == .pasta)
    }

    /// A name can't tell a turkey burger from a beef one, so the nudge never states a protein. The draw still leans.
    @Test(arguments: [
        ["Turkey meatballs", "Pot roast", "Meatloaf"],
        ["Chicken sausage", "Pork tenderloin", "Ham"],
        ["Chicken stir-fry", "Chicken parmesan", "Rotisserie chicken"],
        ["Baked salmon", "Baked tilapia", "Seared scallops"],
    ])
    func aProteinIsNeverANudge(names: [String]) {
        #expect(VarietyNudge.nudge(mealNames: names) == nil)
    }

    @Test func proteinsStillCountInTheDraw() {
        let pinned = LibraryMeal.fixture(name: "Rotisserie chicken")
        let chicken = LibraryMeal.fixture(name: "Chicken parmesan"), other = plainDish()
        var week = nights(from: april, count: 2)
        week[0].locked = true
        week[0].mealID = pinned.id
        let inputs = planning(week, [pinned, chicken, other])
        let picks = seeds.filter { BuildMyWeek.draft(inputs, seed: $0)[1].pick == .meal(chicken.id) }.count
        #expect(picks < 165, "1 in 3, 133")
    }

    @Test func theLayoutNudgesWhileANightCanStillChange() {
        #expect(layout(threePasta).varietyNudge?.category == .pasta)
        #expect(layout(threePasta + [nil], today: 3).varietyNudge?.category == .pasta, "Past nights count")
    }

    @Test func theLayoutDoesNotNudgeWhenNothingCanChange() {
        #expect(layout(threePasta, today: 4).varietyNudge == nil, "Every night is past")
        #expect(layout(threePasta, today: 3, locked: [3]).varietyNudge == nil, "Only a locked night is left")
        #expect(layout(threePasta, today: 3, events: [3]).varietyNudge == nil, "Only an event night is left")
    }

    @Test(arguments: DishCategory.allCases)
    func everyCategoryButAProteinHasATitle(category: DishCategory) {
        let isProtein = [.chicken, .beef, .pork, .seafood].contains(category)
        #expect(isProtein ? category.title == nil : category.title?.isEmpty == false)
    }
}
