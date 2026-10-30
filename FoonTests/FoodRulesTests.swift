import Foundation
import Supabase
import Testing
@testable import Foon

/// Lent's dates, worked out from Easter. The years are from published calendars, including the earliest and latest dates
/// Easter can fall on in this span.
struct LentTests {
    @Test(arguments: [
        (2008, 3, 23), (2024, 3, 31), (2025, 4, 20), (2026, 4, 5), (2027, 3, 28), (2028, 4, 16), (2029, 4, 1),
        (2030, 4, 21), (2038, 4, 25), (2100, 3, 28),
    ])
    func easter(year: Int, month: Int, day: Int) {
        #expect(Lent.easter(year: year) == CalendarDay(year: year, month: month, day: day))
    }

    @Test(arguments: [
        // First Friday after Ash Wednesday, and Good Friday.
        (CalendarDay(year: 2026, month: 2, day: 20), CalendarDay(year: 2026, month: 4, day: 3)),
        (CalendarDay(year: 2027, month: 2, day: 12), CalendarDay(year: 2027, month: 3, day: 26)),
        (CalendarDay(year: 2028, month: 3, day: 3), CalendarDay(year: 2028, month: 4, day: 14)),
        (CalendarDay(year: 2038, month: 3, day: 12), CalendarDay(year: 2038, month: 4, day: 23)),
    ])
    func fridaysRunFromAfterAshWednesdayThroughGoodFriday(first: CalendarDay, last: CalendarDay) {
        #expect(Lent.isFridayInLent(first))
        #expect(Lent.isFridayInLent(last))
        #expect(!Lent.isFridayInLent(first.adding(days: -7)), "the Friday before Ash Wednesday")
        #expect(!Lent.isFridayInLent(last.adding(days: 7)), "the Friday after Easter")
        #expect(Lent.isFridayInLent(first.adding(days: 7)), "one in the middle")
        #expect(!Lent.isFridayInLent(first.adding(days: 1)), "only Fridays")
    }
}

struct FoodRuleMatcherTests {
    private func looks(_ avoid: FoodRule.Avoid, _ name: String, ingredients: [String] = []) -> Bool {
        let meal = LibraryMeal.fixture(name: name, ingredients: ingredients)
        return FoodRuleMatcher.looksLikeIt(avoid, meal: meal, library: [meal])
    }

    @Test(arguments: ["Beef tacos", "Grilled chicken", "Spaghetti bolognese", "Meatloaf", "Turkey burgers", "BLT", "BLTs",
                      "BBQ ribs", "Meatballs",
                      "Pepperoni pizza", "Hot dogs", "Steak night", "Meat sauce", "Sloppy joes", "Shepherd's Pie"])
    func namesThatLookLikeMeat(name: String) {
        #expect(looks(.meat, name))
    }

    @Test(arguments: ["Fish tacos", "Tuna steak", "Crab meat salad", "Shrimp scampi", "Veggie burgers", "Black bean burgers",
                      "Vegetarian chili", "Meatless meatballs", "Impossible burger", "Cauliflower steak", "Grilled cheese",
                      "Mac and cheese", "Goat cheese salad", "Hamburger buns", "Vegan sausage", "Cheese pizza"])
    func namesThatDont(name: String) {
        #expect(!looks(.meat, name))
    }

    /// "Beef and veggie stir fry" says veggie and is still beef: only the word right after it stands in.
    @Test func aVeggieMentionDoesntCancelTheMeat() {
        #expect(looks(.meat, "Beef and veggie stir fry"))
        #expect(looks(.meat, "Veggie and chicken bake"))
    }

    @Test func ingredientsCountNotJustTheName() {
        #expect(looks(.meat, "Sunday special", ingredients: ["2 lb ground beef", "1 onion"]))
        #expect(!looks(.meat, "Sunday special", ingredients: ["1 onion", "hamburger buns", "steak sauce"]))
        #expect(looks(.meat, "Minestrone", ingredients: ["chicken broth"]), "over-matching is the safe way round here")
    }

    @Test func sidesAreOnTheTableToo() {
        let side = LibraryMeal.fixture(name: "Sunday greens", ingredients: ["bacon"])
        var main = LibraryMeal.fixture(name: "Cornbread", ingredients: ["cornmeal"])
        main.sides = [.meal(side.id)]
        #expect(FoodRuleMatcher.looksLikeIt(.meat, meal: main, library: [main, side]))
        #expect(!FoodRuleMatcher.looksLikeIt(.meat, meal: main, library: [main]), "a side it can't find adds nothing")
    }

    @Test func aNameItCantReadPasses() {
        #expect(!looks(.meat, "Grandma's special"), "what the rule can't know, and why it never says meatless")
    }

    @Test(arguments: [("Pulled pork", true), ("Ham and cheese", true), ("Bacon carbonara", true), ("Italian sausage", true),
                      ("BLT", true), ("BLTs", true), ("BBQ ribs", true), ("Ribs", true), ("Hot dogs", true), ("Meatballs", true),
                      ("Turkey meatballs", false), ("Celery ribs and carrots", false), ("Hot dog buns", false),
                      ("Chicken sausage", false), ("Turkey bacon", false), ("Beef tacos", false), ("Veggie sausage", false)])
    func pork(name: String, expected: Bool) {
        #expect(looks(.pork, name) == expected)
    }

    @Test(arguments: [("Shrimp scampi", true), ("Crab cakes", true), ("Clam chowder", true), ("Oyster mushroom pasta", false),
                      ("Fish tacos", false), ("Beef tacos", false)])
    func shellfish(name: String, expected: Bool) {
        #expect(looks(.shellfish, name) == expected)
    }

    @Test func aRuleOnlyAppliesOnItsNights() {
        let burger = LibraryMeal.fixture(name: "Burgers")
        let rules = [FoodRule(avoid: .meat, nights: .lentFridays)]
        let goodFriday = CalendarDay(year: 2027, month: 3, day: 26)
        #expect(FoodRuleMatcher.broken(by: burger, on: goodFriday, rules: rules, library: [burger]) == rules)
        #expect(FoodRuleMatcher.broken(by: burger, on: goodFriday.adding(days: -1), rules: rules, library: [burger]).isEmpty)
        #expect(FoodRuleMatcher.broken(by: burger, on: goodFriday.adding(days: 7), rules: rules, library: [burger]).isEmpty)
    }
}

/// Every path that plans a night. A week in Lent 2027, Sunday to Saturday, with Friday the 19th.
struct FoodRulesPlanningTests {
    private let sunday = CalendarDay(year: 2027, month: 3, day: 14)
    private let friday = CalendarDay(year: 2027, month: 3, day: 19)
    private let nora = UUID(), owen = UUID()
    private let seeds = UInt64(0)..<40

    private func settings(_ rules: [FoodRule] = [FoodRule(avoid: .meat, nights: .lentFridays)]) -> HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.foodRules = rules
        return settings
    }

    private func nights(from start: CalendarDay? = nil) -> [PlanningNight] {
        (0..<7).map { PlanningNight(id: UUID(), date: (start ?? sunday).adding(days: $0), attendance: [nora: true]) }
    }

    private let burgers = LibraryMeal.fixture(name: "Burgers")
    private let steak = LibraryMeal.fixture(name: "Steak")
    private let chicken = LibraryMeal.fixture(name: "Roast chicken")
    private let salmon = LibraryMeal.fixture(name: "Baked salmon")
    private let beans = LibraryMeal.fixture(name: "Rice and beans")
    private var library: [LibraryMeal] { [burgers, steak, chicken, salmon, beans] }

    private func plan(on day: CalendarDay, in plans: [NightPlan]) -> NightPlan? { plans.first { $0.date == day } }

    @Test func aBuildNeverPutsADishThatLooksLikeItBreaksTheRuleOnThatNight() {
        var fridays: Set<UUID> = []
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings()), seed: seed)
            let pick = plan(on: friday, in: plans)?.pick?.mealID
            #expect(pick != nil, "two dishes pass, so Friday gets one")
            if let pick { fridays.insert(pick) }
        }
        #expect(fridays == [salmon.id, beans.id], "the two that pass, and both turn up")
    }

    @Test func aRuleThatDoesntApplyThatWeekChangesNothing() {
        // The same nights in June: no Lent, so the same seed draws the same dishes as with no rule at all.
        let june = CalendarDay(year: 2027, month: 6, day: 13)
        let week = nights(from: june)
        for seed in seeds {
            let with = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library, settings: settings()), seed: seed)
            let without = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library, settings: settings([])), seed: seed)
            #expect(with == without)
        }
    }

    @Test func outsideTheRuleTheDishStillGetsPlanned() {
        var plannedElsewhere = false
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings()), seed: seed)
            plannedElsewhere = plannedElsewhere || plans.contains { $0.date != friday && $0.pick?.mealID == burgers.id }
        }
        #expect(plannedElsewhere, "a rule for Fridays doesn't take it off Monday")
    }

    @Test func withNothingElseTheNightSaysNothingFitsRatherThanAWrongDish() {
        // Plenty of dishes for every night: only the rule leaves Friday short.
        let meaty = (0..<9).map { LibraryMeal.fixture(name: "Beef dish \($0)") }
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: meaty, settings: settings()), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == nil)
            #expect(plan(on: friday, in: plans)?.reason == .nothingFits)
            #expect(plans.filter { $0.pick != nil }.count == 6, "the other nights fill as usual")
        }
    }

    @Test func aRuleThatOnlyMakesItHarderDoesntLeaveANightEmpty() {
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library + [.fixture(name: "Tomato soup"),
                                                                                             .fixture(name: "Veggie stir fry")],
                                                         settings: settings()), seed: seed)
            #expect(plans.allSatisfy { $0.pick != nil })
        }
    }

    /// Date order would spend the dish on Monday, when Monday could have had anything, and leave Friday with nothing.
    @Test func aSpecialSlotDoesntSpendTheOneDishTheRuleNightCanHave() {
        var withBatch = settings()
        withBatch.leftoverNights = 1
        let lentils = LibraryMeal.fixture(name: "Lentil stew", tags: [.leftovers])
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: [burgers, steak, chicken, lentils], settings: withBatch), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == .meal(lentils.id))
        }
    }

    /// Takeout is a dinner the rule has nothing to say about, and a rushed Friday is a rushed night like any other.
    @Test func aRushedRuleNightTakesTakeoutFirst() {
        var takeout = settings()
        takeout.takeoutNights = 1
        var week = nights()
        let index = week.firstIndex { $0.date == friday }!
        week[index].effort = .rushed
        let quick = LibraryMeal.fixture(name: "Quick lentils", tags: [.quick])
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library + [quick], settings: takeout), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == .quickPick(.takeout))
            #expect(plan(on: friday, in: plans)?.reason == .takeoutOnBusiestNight)
        }
    }

    /// Monday can only have the quick dish; Friday could have had it, and is the one that goes without.
    @Test func anOrdinaryRuleNightDrawsAfterRushedNights() {
        var week = nights()
        let monday = week.firstIndex { $0.date == sunday.adding(days: 1) }!
        week[monday].effort = .rushed
        let quick = LibraryMeal.fixture(name: "Quick lentils", tags: [.quick])
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: [burgers, steak, chicken, quick], settings: settings()), seed: seed)
            #expect(plan(on: week[monday].date, in: plans)?.pick == .meal(quick.id))
            #expect(plan(on: friday, in: plans)?.reason == .nothingFits)
        }
    }

    /// A household with no rule that applies draws exactly as before, whatever else the week has going on.
    @Test func withNoRuleNightTheOrderIsUntouched() {
        var busy = settings()
        busy.takeoutNights = 1
        busy.leftoverNights = 1
        busy.newDishesPerWeek = 1
        var week = nights(from: CalendarDay(year: 2027, month: 6, day: 13))
        week[1].effort = .rushed
        let meals = library + [.fixture(name: "Quick lentils", tags: [.quick]), .fixture(name: "Bean stew", tags: [.leftovers]),
                               .fixture(name: "New curry", status: .trial)]
        var none = busy
        none.foodRules = []
        for seed in seeds {
            #expect(BuildMyWeek.draft(PlanningInputs(nights: week, meals: meals, settings: busy), seed: seed)
                == BuildMyWeek.draft(PlanningInputs(nights: week, meals: meals, settings: none), seed: seed))
        }
    }

    @Test func fillLeavesWhatThePlannerChoseAndFollowsTheRule() {
        // Fill locks what's already planned, then drafts: the planner's burgers stay on Friday, and it's not the rule's job.
        var week = nights()
        let index = week.firstIndex { $0.date == friday }!
        week[index].mealID = burgers.id
        week[index].locked = true
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library, settings: settings()), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == .meal(burgers.id))
        }
        // Nothing planned on Friday: Fill won't put a burger there.
        for seed in seeds {
            var open = nights()
            open[0].mealID = beans.id
            open[0].locked = true
            let plans = BuildMyWeek.draft(PlanningInputs(nights: open, meals: library, settings: settings()), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == .meal(salmon.id))
        }
    }

    @Test func shuffleAndPickForMeFollowTheRule() {
        let week = nights()
        let night = week.first { $0.date == friday }!
        for seed in seeds {
            let picked = BuildMyWeek.shuffle(night: night.id, inputs: PlanningInputs(nights: week, meals: library, settings: settings()),
                                             seed: seed)
            #expect(picked?.pick?.mealID == salmon.id || picked?.pick?.mealID == beans.id)
        }
        #expect(BuildMyWeek.shuffle(night: night.id, inputs: PlanningInputs(nights: week, meals: [burgers, steak], settings: settings()),
                                    seed: 1) == nil, "nothing fits, so the night stays as it is")
    }

    @Test func swapSuggestionsFollowTheRule() {
        let week = nights()
        let night = week.first { $0.date == friday }!
        let picks = Set(seeds.flatMap { seed in
            BuildMyWeek.suggestions(night: night.id, inputs: PlanningInputs(nights: week, meals: library, settings: settings()), seed: seed)
                .map(\.mealID)
        })
        #expect(picks == [salmon.id, beans.id])
    }

    @Test func aPastNightIsLoggingWhatWasEaten() {
        let week = nights()
        let night = week.first { $0.date == friday }!
        let picks = Set(seeds.flatMap { seed in
            BuildMyWeek.suggestions(night: night.id, inputs: PlanningInputs(nights: week, meals: library, settings: settings(),
                                                                            today: friday.adding(days: 1)), seed: seed)
                .map(\.mealID)
        })
        #expect(picks.contains(burgers.id), "they had burgers; the rule doesn't say they didn't")
    }

    // MARK: Requests and traditions aren't dropped

    @Test func aDatedRequestStillLandsOnItsNight() {
        let request = DatedRequest(mealID: burgers.id, date: friday, requesterID: nora)
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings(),
                                                     memberNames: [nora: "Nora"], requests: [request]), seed: 1)
        #expect(plan(on: friday, in: plans)?.pick == .meal(burgers.id), "the family asked out loud; the card says what it looks like")
        #expect(plan(on: friday, in: plans)?.reason == .request(name: "Nora"))
    }

    @Test func aSomedayRequestTakesANightTheRuleDoesntApplyTo() {
        // Everyone home only on Friday and Saturday: it goes to Saturday, not the first night they're home.
        var week = nights()
        for index in week.indices where week[index].date < friday { week[index].attendance[nora] = false }
        let wanted = WantedRequest(mealID: burgers.id, requesterID: nora, wanters: [nora])
        let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library, settings: settings(), wanted: [wanted]), seed: 1)
        #expect(plan(on: friday.adding(days: 1), in: plans)?.pick == .meal(burgers.id))
        #expect(plan(on: friday, in: plans)?.pick != .meal(burgers.id))
    }

    @Test func aSomedayRequestWithNoOtherNightStillLandsRatherThanVanishing() {
        var week = nights()
        for index in week.indices where week[index].date != friday { week[index].attendance[nora] = false }
        let wanted = WantedRequest(mealID: burgers.id, requesterID: nora, wanters: [nora])
        let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: library, settings: settings(), wanted: [wanted]), seed: 1)
        #expect(plan(on: friday, in: plans)?.pick == .meal(burgers.id))
    }

    @Test func aTraditionTheRuleRulesOutSitsOutAndTheNightSaysSo() {
        let tradition = Tradition(weekday: 5, pick: .meal(burgers.id), name: "Burger Friday")
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings(), traditions: [tradition]), seed: 1)
        let night = plan(on: friday, in: plans)
        #expect(night?.pick != .meal(burgers.id))
        #expect(night?.pick != nil, "the night still gets a dinner")
        #expect(night?.reason == .traditionSatOut(name: "Burger Friday"))
        #expect(night?.reason?.text == "Burger Friday sat out for a food rule")
        #expect(night?.locks == false, "it isn't the tradition, so it isn't locked as one")
    }

    @Test func aTraditionTheRuleLeavesAloneLandsAsUsual() {
        let tradition = Tradition(weekday: 5, pick: .meal(salmon.id), name: "Fish Friday")
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings(), traditions: [tradition]), seed: 1)
        #expect(plan(on: friday, in: plans)?.pick == .meal(salmon.id))
        #expect(plan(on: friday, in: plans)?.reason == .tradition(name: "Fish Friday"))
    }

    @Test func aTraditionOutsideLentLandsOnItsFriday() {
        let june = CalendarDay(year: 2027, month: 6, day: 13)
        let tradition = Tradition(weekday: 5, pick: .meal(burgers.id), name: "Burger Friday")
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(from: june), meals: library, settings: settings(), traditions: [tradition]), seed: 1)
        #expect(plan(on: june.adding(days: 5), in: plans)?.pick == .meal(burgers.id))
    }

    @Test func aQuickPickTraditionIsntReadAsADish() {
        let tradition = Tradition(weekday: 5, pick: .quickPick(.takeout), name: "Takeout Friday")
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: library, settings: settings(), traditions: [tradition]), seed: 1)
        #expect(plan(on: friday, in: plans)?.pick == .quickPick(.takeout))
    }

    // MARK: Leftovers are the same dish

    /// Only Thursday and Friday are open, and the only big batch is beef. Friday has nothing the rule allows, so it's still
    /// open when leftovers are placed: beef on Thursday would feed it.
    @Test func aBigBatchIsntDrawnToFeedTheRulesNight() {
        var withLeftovers = settings()
        withLeftovers.leftoverNights = 1
        let batch = LibraryMeal.fixture(name: "Beef stew", tags: [.leftovers])
        var week = nights()
        for index in week.indices where week[index].date != friday && week[index].date != friday.adding(days: -1) {
            week[index].effort = .event
        }
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: [batch], settings: withLeftovers), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == nil)
            #expect(plan(on: friday, in: plans)?.reason == .nothingFits)
        }
    }

    @Test func aKeptMeatBatchDoesntTurnFridayIntoItsLeftovers() {
        var withLeftovers = settings()
        withLeftovers.leftoverNights = 1
        let batch = LibraryMeal.fixture(name: "Beef stew", tags: [.leftovers])
        var week = nights()
        let thursday = week.firstIndex { $0.date == friday.adding(days: -1) }!
        week[thursday].mealID = batch.id
        week[thursday].locked = true
        // Only meat, so Friday's still open when leftovers are placed: nothing else has taken it.
        for seed in seeds {
            let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: [batch, burgers, steak], settings: withLeftovers), seed: seed)
            #expect(plan(on: friday, in: plans)?.pick == nil)
            #expect(plan(on: friday, in: plans)?.reason == .nothingFits)
        }
    }

    @Test func leftoversWithNoDishBehindThemKeepOffTheRulesNight() {
        var withLeftovers = settings()
        withLeftovers.leftoverNights = 1
        var week = nights()
        // Thursday and Friday are open, there's no big batch, and Friday has no dish: a leftovers night with nothing behind
        // it could be anything, so it goes to Thursday, though it would otherwise take the later night.
        for index in week.indices where week[index].date != friday && week[index].date != friday.adding(days: -1) {
            week[index].effort = .event
        }
        let plans = BuildMyWeek.draft(PlanningInputs(nights: week, meals: [burgers], settings: withLeftovers), seed: 1)
        #expect(plan(on: friday.adding(days: -1), in: plans)?.pick == .quickPick(.leftovers))
        #expect(plan(on: friday, in: plans)?.pick == nil)
    }

    @Test func aRuleForEveryNightDoesntStopLeftoversNights() {
        var withLeftovers = settings([FoodRule(avoid: .meat, nights: .everyNight)])
        withLeftovers.leftoverNights = 1
        let plans = BuildMyWeek.draft(PlanningInputs(nights: nights(), meals: [salmon, beans], settings: withLeftovers), seed: 1)
        #expect(plans.contains { $0.pick == .quickPick(.leftovers) }, "what's left over already passed the rule")
    }

    @Test func shufflingADishThatFeedsLeftoversFollowsTomorrowsRule() {
        var week = nights()
        let thursday = week.firstIndex { $0.date == friday.adding(days: -1) }!
        let beanStew = LibraryMeal.fixture(name: "Bean stew", tags: [.leftovers])
        let beefStew = LibraryMeal.fixture(name: "Beef stew", tags: [.leftovers])
        let lentil = LibraryMeal.fixture(name: "Lentil stew", tags: [.leftovers])
        week[thursday].mealID = beanStew.id
        week[thursday + 1].quickPick = .leftovers
        for seed in seeds {
            let picked = BuildMyWeek.shuffle(night: week[thursday].id, inputs: PlanningInputs(nights: week, meals: [beanStew, beefStew, lentil], settings: settings()),
                                             seed: seed)
            #expect(picked?.pick == .meal(lentil.id), "beef stew would be on Friday too")
        }
    }

    // MARK: Freezer

    private func night(_ date: CalendarDay, meal: UUID? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: date, effort: .normal, dinnerTime: nil, mealID: meal, mealName: nil, quickPick: nil,
                  locked: false, attendance: [nora: true])
    }

    @Test func theFreezerFollowsTheRuleExceptForWhatWasAlreadyEaten() {
        let stew = LibraryMeal.fixture(name: "Beef stew")
        let lentils = LibraryMeal.fixture(name: "Lentils")
        let items = [stew, lentils].map {
            FreezerItem(id: UUID(), mealID: $0.id, mealName: $0.name, madeOn: sunday.adding(days: -20), state: .in)
        }
        let rules = settings().foodRules
        func offered(_ date: CalendarDay, today: CalendarDay) -> [UUID] {
            let target = night(date)
            return FreezerStash.offers(items, on: target, week: [target], library: [stew, lentils], notForMe: [:], snoozed: [], allergies: [],
                                       today: today, foodRules: rules).map(\.meal.id)
        }
        #expect(offered(friday, today: sunday) == [lentils.id])
        #expect(offered(friday.adding(days: -1), today: sunday).count == 2, "Thursday's not a rule night")
        #expect(offered(friday, today: friday.adding(days: 1)).count == 2, "logging a past night")
    }

    // MARK: Swap's held-back list

    @Test func heldBackLeavesOutWhatsAlreadyInTheWeekAndWhyTheRestAreThere() {
        let target = night(friday, meal: burgers.id)
        let elsewhere = night(friday.adding(days: -1), meal: steak.id)
        let held = FoodRuleMatcher.heldBack(on: target, week: [target, elsewhere], meals: library + [.fixture(name: "Old roast beef", status: .archived)],
                                            rules: settings().foodRules)
        #expect(held.map(\.meal.id) == [chicken.id], "not tonight's own dish, nor one on another night, nor one out of rotation")
        #expect(held.first?.rules == settings().foodRules)
    }

    // MARK: The card and Plan it say so

    @Test func theCardSaysWhatItLooksLikeOnANightItApplies() {
        let settings = settings()
        #expect(NightBadges.badges(meal: burgers, library: library, allergies: [], home: [], settings: settings, ruleDay: friday)
            == [.foodRule("Looks like it has meat: Fridays in Lent")])
        #expect(NightBadges.badges(meal: burgers, library: library, allergies: [], home: [], settings: settings,
                                   ruleDay: friday.adding(days: -1)).isEmpty)
        #expect(NightBadges.badges(meal: salmon, library: library, allergies: [], home: [], settings: settings, ruleDay: friday).isEmpty,
                "and never says anything about a dish that passes")
    }

    @Test func leftoversOrAFreezerDishStillCarryTheBadge() {
        let badges = NightBadges.badges(meal: burgers, library: library, allergies: [], home: [], settings: settings(),
                                        alreadyCooked: true, ruleDay: friday)
        #expect(badges == [.foodRule("Looks like it has meat: Fridays in Lent")])
    }

    @MainActor
    @Test func thePlanCardOnlyMentionsItForANightAhead() {
        let tonight = night(friday, meal: burgers.id)
        func badges(today: CalendarDay) -> [DayCardModel.Badge] {
            WeekStore.planCard(for: tonight, nights: [tonight], members: [], library: library, allergies: [], settings: settings(),
                               today: today, minuteNow: 0).badges
        }
        #expect(badges(today: sunday).contains(.foodRule("Looks like it has meat: Fridays in Lent")))
        #expect(!badges(today: friday.adding(days: 1)).contains(.foodRule("Looks like it has meat: Fridays in Lent")),
                "it's been eaten; nobody needs telling")
    }

    @Test func planItSaysSoBeforeThePlannerPicksTheNight() {
        #expect(PlanIt.foodRuleWarnings(for: burgers, on: night(friday), settings: settings(), library: library)
            == ["Looks like it has meat: Fridays in Lent"])
        #expect(PlanIt.foodRuleWarnings(for: burgers, on: night(friday.adding(days: -1)), settings: settings(), library: library).isEmpty)
    }
}

struct FoodRuleSettingsTests {
    private func decode(_ json: String) throws -> HouseholdSettings {
        try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
    }

    @Test func aRuleFromANewerAppCostsNothingElse() throws {
        let settings = try decode(#"""
        {"takeout_nights": 2, "food_rules": [{"avoid": "dairy", "when": "every_night"},
                                             {"avoid": "meat", "when": "advent"},
                                             {"avoid": "meat", "when": "lent_fridays"}]}
        """#)
        #expect(settings.foodRules == [FoodRule(avoid: .meat, nights: .lentFridays)])
        #expect(settings.takeoutNights == 2)
        #expect(try decode(#"{"food_rules": "none"}"#).foodRules.isEmpty)
    }

    @Test func aSettingsSaveDoesntCarryThem() throws {
        var settings = HouseholdSettings()
        settings.foodRules = [FoodRule(avoid: .pork, nights: .everyNight)]
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!saved.contains("food_rules"), "a stale copy can't undo another planner's rule")
    }
}

@MainActor
struct FoodRuleStoreTests {
    private func household(_ rules: [FoodRule] = []) -> Household {
        var settings = HouseholdSettings()
        settings.foodRules = rules
        return Household(id: UUID(), name: "The Smiths", emoji: nil, owner: nil, settings: settings)
    }

    @Test func showsTheListTheServerSendsBack() async {
        let household = household()
        let otherPlanners = FoodRule(avoid: .pork, nights: .everyNight)
        let mine = FoodRule(avoid: .meat, nights: .lentFridays)
        var client = HouseholdClient.preview(household: household)
        client.setFoodRule = { _, avoid, nights in
            #expect(avoid == .meat)
            #expect(nights == .lentFridays)
            return [otherPlanners, mine]
        }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(await store.setFoodRule(.meat, nights: .lentFridays))
        #expect(store.household?.planningSettings.foodRules == [otherPlanners, mine])
    }

    @Test func aRefusalSaysWhoCanAndAFailureSaysCheckYourConnection() async {
        let household = household()
        var client = HouseholdClient.preview(household: household)
        client.setFoodRule = { _, _, _ in throw PostgrestError(code: "42501", message: "only planners") }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(await store.setFoodRule(.meat, nights: .fridays) == false)
        #expect(store.errorMessage == "Only planners can change food rules.")

        client.setFoodRule = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let offline = HouseholdStore(userID: UUID(), client: client)
        await offline.load()
        #expect(await offline.setFoodRule(.meat, nights: .fridays) == false)
        #expect(offline.errorMessage == "Couldn't save the food rule. Check your connection and try again.")
    }

    @Test func aSettingsSaveFromAnOlderCopyDoesntPutOldRulesBackOnScreen() async {
        let rule = FoodRule(avoid: .meat, nights: .fridays)
        let store = HouseholdStore(userID: UUID(), client: .preview(household: household([rule])))
        await store.load()
        var stale = HouseholdSettings()
        stale.takeoutNights = 3
        #expect(await store.updateSettings(stale))
        #expect(store.household?.planningSettings.takeoutNights == 3)
        #expect(store.household?.planningSettings.foodRules == [rule])
    }
}
