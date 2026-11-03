import Foundation
import Testing
@testable import Foon

/// Tonight rescue (#60): three ideas for a dinner that fell through, from what's already in the house.
struct TonightRescueTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)
    private let ana = UUID()
    private let ben = UUID()
    private let tonightID = UUID()

    // MARK: - Fixtures

    private func tonight(mealID: UUID? = nil, quickPick: QuickPick? = nil, attendance: [UUID: Bool]? = nil,
                         effort: NightEffort = .normal) -> WeekNight {
        WeekNight(id: tonightID, date: today, effort: effort, dinnerTime: "18:30", mealID: mealID, mealName: nil,
                  quickPick: quickPick, locked: false, attendance: attendance ?? [ana: true, ben: true])
    }

    private func dish(_ name: String, _ minutes: Int? = 15, tags: [MealTag] = [], status: MealStatus = .active,
                      ingredients: [String] = [], prepSteps: [PrepStep] = []) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: name, tags: tags, status: status, ingredients: ingredients,
                                       prepSteps: prepSteps)
        meal.cookMinutes = minutes
        return meal
    }

    private func backup(_ name: String, _ minutes: Int? = 15, ingredients: [String] = []) -> LibraryMeal {
        dish(name, minutes, tags: [.backup], ingredients: ingredients)
    }

    private func frozen(_ meal: LibraryMeal, daysAgo: Int = 20) -> FreezerItem {
        FreezerItem(id: UUID(), mealID: meal.id, mealName: meal.name, madeOn: today.adding(days: -daysAgo), state: .in)
    }

    private func log(_ meal: LibraryMeal, daysAgo: Int, leftovers: Bool? = true) -> DinnerLog {
        DinnerLog(id: UUID(), nightID: UUID(), date: today.adding(days: -daysAgo), mealID: meal.id, mealName: meal.name,
                  quickPick: nil, leftovers: leftovers)
    }

    private func leftoversEaten(daysAgo: Int) -> DinnerLog {
        DinnerLog(id: UUID(), nightID: UUID(), date: today.adding(days: -daysAgo), mealID: nil, mealName: nil,
                  quickPick: .leftovers, leftovers: false)
    }

    private func ideas(minutes: Int = 30, night: WeekNight? = nil, meals: [LibraryMeal] = [],
                       history: [MealHistory] = [],
                       settings: HouseholdSettings = HouseholdSettings(), notForMe: [UUID: [UUID: Int]] = [:],
                       snoozed: Set<UUID> = [], freezer: [FreezerItem] = [], logs: [DinnerLog] = [],
                       stock: [UUID: StockState] = [:], allergies: [MemberAllergies] = [], seed: UInt64 = 1,
                       count: Int = 3) -> [TonightRescue.Idea] {
        let night = night ?? tonight()
        let planning = PlanningInputs(nights: [PlanningNight(night)], meals: meals, history: history,
                                      settings: settings, notForMe: notForMe, snoozedMealIDs: snoozed, today: today)
        return TonightRescue.ideas(minutes: minutes, nightID: night.id, week: [night], planning: planning,
                                   freezer: freezer, logs: logs, stock: stock, allergies: allergies, seed: seed,
                                   count: count)
    }

    private func kinds(_ ideas: [TonightRescue.Idea]) -> [String] {
        ideas.map { idea in
            switch idea.kind {
            case .leftovers: "leftovers"
            case .freezer: "freezer"
            case .backup: "backup"
            case .quickDish: "dish"
            case .quickPick(let pick): pick.rawValue
            }
        }
    }

    // MARK: - Count and fillers

    @Test func nothingInTheHouseStillGivesThreeIdeas() {
        let ideas = ideas()
        #expect(kinds(ideas) == ["takeout", "freezer_raid", "fend_for_yourselves"])
        #expect(ideas.first?.why == "Nothing to cook")
        #expect(ideas.allSatisfy { $0.minutes == nil })
    }

    @Test func fillersSkipTonightsOwnPick() {
        #expect(kinds(ideas(night: tonight(quickPick: .takeout))) == ["freezer_raid", "fend_for_yourselves", "eat_out"])
    }

    @Test func freezerRaidOnlyWithoutAFreezerIdea() {
        let chili = dish("Chili", nil)
        #expect(kinds(ideas(meals: [chili], freezer: [frozen(chili)])) == ["freezer", "takeout", "fend_for_yourselves"])
    }

    @Test func alwaysExactlyTheCountAsked() {
        let meals = (1...8).map { backup("Backup \($0)") } + (1...8).map { dish("Dish \($0)") }
        #expect(ideas(meals: meals).count == 3)
        #expect(ideas(meals: meals, count: 5).count == 5)
        #expect(ideas(count: 1).count == 1)
    }

    // MARK: - Seed

    @Test func theSameSeedGivesTheSameIdeasWhateverOrderTheLibraryCameIn() {
        let meals = (1...12).map { dish("Dish \($0)") }
        let first = ideas(meals: meals, seed: 42)
        #expect(ideas(meals: meals, seed: 42) == first)
        #expect(ideas(meals: meals.reversed(), seed: 42) == first)
    }

    @Test func anotherSeedChangesTheQuickDraw() {
        let meals = (1...12).map { dish("Dish \($0)") }
        let firsts = Set((1...20).compactMap { ideas(meals: meals, seed: UInt64($0)).first?.title })
        #expect(firsts.count > 1)
    }

    // MARK: - Picking

    @Test func oneFromEachPoolInOrder() {
        let (stew, chili, pizza, eggs) = (dish("Stew", nil), dish("Chili", nil), backup("Pizza"), dish("Eggs"))
        let ideas = ideas(meals: [stew, chili, pizza, eggs], freezer: [frozen(chili)], logs: [log(stew, daysAgo: 1)],
                          count: 4)
        #expect(kinds(ideas) == ["leftovers", "freezer", "backup", "dish"])
        #expect(ideas.map(\.title) == ["Stew", "Chili", "Pizza", "Eggs"])
    }

    @Test func theSecondRoundIsMoreBackupsThenDishes() {
        let meals = [backup("Pizza"), backup("Nuggets"), dish("Eggs"), dish("Quesadillas")]
        #expect(kinds(ideas(meals: meals, count: 4)) == ["backup", "dish", "backup", "dish"])
    }

    @Test func theSecondRoundNeverTakesASecondLeftoversOrFreezer() {
        let (stew, soup) = (dish("Stew", nil), dish("Soup", nil))
        let (chili, lasagna) = (dish("Chili", nil), dish("Lasagna", nil))
        let ideas = ideas(meals: [stew, soup, chili, lasagna], freezer: [frozen(chili), frozen(lasagna)],
                          logs: [log(stew, daysAgo: 1), log(soup, daysAgo: 2)])
        #expect(kinds(ideas) == ["leftovers", "freezer", "takeout"])
    }

    @Test func tonightsOwnDishIsNeverOffered() {
        let (eggs, pizza, chili) = (dish("Eggs"), backup("Pizza"), dish("Chili", nil))
        let freezer = [frozen(chili)]
        let logs = [log(chili, daysAgo: 1)]
        for held in [eggs, pizza, chili] {
            let titles = ideas(night: tonight(mealID: held.id), meals: [eggs, pizza, chili], freezer: freezer,
                               logs: logs, count: 6).map(\.title)
            #expect(!titles.contains(held.name), "\(held.name) is already tonight's dinner")
        }
    }

    @Test func leftoversAreNeverOfferedOnALeftoversNight() {
        let stew = dish("Stew", nil)
        #expect(!kinds(ideas(night: tonight(quickPick: .leftovers), meals: [stew], logs: [log(stew, daysAgo: 1)]))
            .contains("leftovers"))
    }

    // MARK: - Time

    @Test func aDishsOwnTimeBeatsItsQuickTag() {
        #expect(ideas(meals: [dish("Stir fry", 40, tags: [.quick])]).allSatisfy { $0.title != "Stir fry" })
    }

    @Test func aQuickDishIsAroundThirtyMinutes() throws {
        let tacos = dish("Tacos", nil, tags: [.quick])
        let idea = try #require(ideas(meals: [tacos]).first)
        #expect(idea.title == "Tacos")
        #expect(idea.minutes == 30)
        #expect(idea.isEstimate)
        #expect(idea.why.hasSuffix(" · around 30 min"))
        #expect(ideas(minutes: 20, meals: [tacos]).allSatisfy { $0.title != "Tacos" })
    }

    @Test func aDishsOwnTimeIsShown() throws {
        let idea = try #require(ideas(meals: [dish("Eggs", 25)]).first)
        #expect(idea.minutes == 25)
        #expect(!idea.isEstimate)
        #expect(idea.why.hasSuffix(" · 25 min"))
    }

    @Test func aSlowCookerNeverFits() {
        let meals = [dish("Pot roast", nil, tags: [.slowCooker]), dish("Crockpot chili", nil),
                     dish("Ribs", nil, tags: [.slowCooker, .backup])]
        #expect(kinds(ideas(minutes: 45, meals: meals)) == ["takeout", "freezer_raid", "fend_for_yourselves"])
    }

    @Test func aLibraryDishWithNoTimeIsLeftOut() {
        #expect(ideas(meals: [dish("Lasagna", nil)]).allSatisfy { $0.title != "Lasagna" })
    }

    @Test func aBackupWithNoTimeComesAfterTimedOnes() {
        let ideas = ideas(meals: [backup("Pizza", nil), backup("Nuggets", 15)])
        #expect(ideas.prefix(2).map(\.title) == ["Nuggets", "Pizza"])
        #expect(ideas[1].minutes == nil)
        #expect(ideas[1].why == "Backup dinner · time not set")
        #expect(ideas[0].why.hasSuffix(" · 15 min"))
    }

    @Test func aBackupOverTheTimeIsDropped() {
        #expect(ideas(minutes: 20, meals: [backup("Pizza", 25)]).allSatisfy { $0.title != "Pizza" })
        #expect(ideas(minutes: 30, meals: [backup("Pizza", 25)]).first?.title == "Pizza")
    }

    @Test func backupsNeverMadeComeFirstThenTheLeastRecent() {
        let (recent, old, never) = (backup("Recent"), backup("Old"), backup("Never"))
        let history = [MealHistory(mealID: recent.id, timesMade: 3, lastMade: today.adding(days: -5)),
                       MealHistory(mealID: old.id, timesMade: 3, lastMade: today.adding(days: -40))]
        #expect(ideas(meals: [recent, old, never], history: history).map(\.title) == ["Never", "Old", "Recent"])
    }

    @Test func aRushedNightStillGetsDishesThatFitTheTime() {
        #expect(ideas(night: tonight(effort: .rushed), meals: [dish("Eggs", 10)]).first?.title == "Eggs")
    }

    // MARK: - Prep ahead

    @Test func aDishWithAPrepStepAheadIsLeftOut() {
        let marinated = dish("Kebabs", 15, prepSteps: [PrepStep(step: "Marinate the chicken", leadHours: 2)])
        #expect(ideas(meals: [marinated]).allSatisfy { $0.title != "Kebabs" })
    }

    @Test func aThawFirstDishIsLeftOutWhenMeatIsKeptFrozen() {
        let thaw = PrepStep(step: "Thaw the beef", leadHours: 24)
        let burgers = dish("Burgers", 15, tags: [.thawFirst], prepSteps: [thaw])
        #expect(ideas(meals: [burgers]).allSatisfy { $0.title != "Burgers" })
        var settings = HouseholdSettings()
        settings.keepsMeatFrozen = false
        #expect(ideas(meals: [burgers], settings: settings).first?.title == "Burgers")
    }

    // MARK: - Dislikes and snoozes

    private var everyPool: (meals: [LibraryMeal], freezer: [FreezerItem], logs: [DinnerLog]) {
        let (stew, chili, pizza, eggs) = (dish("Stew", nil), dish("Chili", nil), backup("Pizza"), dish("Eggs"))
        return ([stew, chili, pizza, eggs], [frozen(chili)], [log(stew, daysAgo: 1)])
    }

    @Test func notForMeFromSomeoneHomeSkipsEveryPool() {
        let pools = everyPool
        let notForMe = Dictionary(uniqueKeysWithValues: pools.meals.map { ($0.id, [ben: 1]) })
        let fillers = ["takeout", "freezer_raid", "fend_for_yourselves"]
        #expect(kinds(ideas(meals: pools.meals, notForMe: notForMe, freezer: pools.freezer, logs: pools.logs))
            == fillers)
        let benOut = tonight(attendance: [ana: true, ben: false])
        #expect(kinds(ideas(night: benOut, meals: pools.meals, notForMe: notForMe, freezer: pools.freezer,
                            logs: pools.logs, count: 4)) == ["leftovers", "freezer", "backup", "dish"])
    }

    @Test func aSnoozeSkipsEveryPool() {
        let pools = everyPool
        #expect(kinds(ideas(meals: pools.meals, snoozed: Set(pools.meals.map(\.id)), freezer: pools.freezer,
                            logs: pools.logs)) == ["takeout", "freezer_raid", "fend_for_yourselves"])
    }

    @Test func aFoodRuleSkipsEveryPool() {
        let (stew, chili) = (dish("Stew", nil, ingredients: ["beef"]), dish("Chili", nil, ingredients: ["ground beef"]))
        let (pizza, tacos) = (backup("Pizza", ingredients: ["pepperoni"]), dish("Tacos", ingredients: ["ground beef"]))
        var settings = HouseholdSettings()
        settings.foodRules = [FoodRule(avoid: .meat, nights: .everyNight)]
        let ideas = ideas(meals: [stew, chili, pizza, tacos], settings: settings, freezer: [frozen(chili)],
                          logs: [log(stew, daysAgo: 1)])
        #expect(kinds(ideas) == ["takeout", "freezer_raid", "fend_for_yourselves"])
    }

    // MARK: - Stock

    @Test func anIngredientMarkedOutRulesADishOut() {
        let (pizza, eggs) = (backup("Pizza", ingredients: ["frozen pizza"]), dish("Eggs", ingredients: ["eggs"]))
        let out = [pizza.ingredients[0].itemID: StockState.out, eggs.ingredients[0].itemID: .out]
        #expect(kinds(ideas(meals: [pizza, eggs], stock: out)) == ["takeout", "freezer_raid", "fend_for_yourselves"])
        let low = [pizza.ingredients[0].itemID: StockState.low]
        #expect(kinds(ideas(meals: [pizza, eggs], stock: low)).prefix(2) == ["backup", "dish"])
    }

    @Test func backupDinnersShareTheStockRule() {
        let pizza = backup("Pizza", ingredients: ["frozen pizza"])
        #expect(PollRules.isInStock(pizza, stock: [:]))
        #expect(PollRules.isInStock(pizza, stock: [pizza.ingredients[0].itemID: .low]))
        #expect(!PollRules.isInStock(pizza, stock: [pizza.ingredients[0].itemID: .out]))
    }

    @Test func whatsOnHandCounts() {
        let eggs = dish("Eggs", ingredients: ["eggs", "toast"])
        let stock = [eggs.ingredients[0].itemID: StockState.in, eggs.ingredients[1].itemID: .low]
        #expect(ideas(meals: [eggs], stock: stock).first?.why.hasPrefix(PlanReason.usesWhatsOnHand.text) == true)
        #expect(ideas(meals: [eggs]).first?.why.hasPrefix(PlanReason.usesWhatsOnHand.text) == false)
    }

    // MARK: - Allergies

    @Test func allergiesFlagNeverFilterAndUnflaggedComeFirst() {
        let peanut = backup("Peanut noodles", ingredients: ["peanut butter", "noodles"])
        let plain = backup("Buttered noodles", ingredients: ["noodles"])
        let allergies = [MemberAllergies(memberID: ana, firstName: "Ana", allergens: [.peanuts])]
        let ideas = ideas(meals: [peanut, plain], allergies: allergies)
        #expect(ideas.prefix(2).map(\.title) == ["Buttered noodles", "Peanut noodles"])
        #expect(ideas[0].allergies.flags.isEmpty)
        #expect(!ideas[1].allergies.flags.isEmpty)
    }

    @Test func someoneWithNoAttendanceRowStillCountsForAllergies() {
        let peanut = backup("Peanut noodles", ingredients: ["peanut butter"])
        let allergies = [MemberAllergies(memberID: ana, firstName: "Ana", allergens: [.peanuts])]
        let night = tonight(attendance: [ben: true])
        #expect(ideas(night: night, meals: [peanut], allergies: allergies).first?.allergies.flags.isEmpty == false)
    }

    @Test func someoneOutTonightDoesntFlag() {
        let peanut = backup("Peanut noodles", ingredients: ["peanut butter"])
        let allergies = [MemberAllergies(memberID: ana, firstName: "Ana", allergens: [.peanuts])]
        let night = tonight(attendance: [ana: false, ben: true])
        #expect(ideas(night: night, meals: [peanut], allergies: allergies).first?.allergies.flags.isEmpty == true)
    }

    // MARK: - Leftovers

    @Test func leftoversComeFromTheLastThreeDays() {
        let meals = (0...4).map { dish("Dish \($0)", nil) }
        let logs = meals.enumerated().map { log($1, daysAgo: $0) }
        #expect(ideas(meals: meals, logs: logs).first?.title == "Dish 3")
    }

    @Test func leftoversMustHaveBeenSaid() {
        let (stew, soup) = (dish("Stew", nil), dish("Soup", nil))
        let logs = [log(stew, daysAgo: 1, leftovers: false), log(soup, daysAgo: 1, leftovers: nil)]
        #expect(!kinds(ideas(meals: [stew, soup], logs: logs)).contains("leftovers"))
    }

    @Test func aLaterLeftoversDinnerAteThem() {
        let (stew, soup) = (dish("Stew", nil), dish("Soup", nil))
        let logs = [log(stew, daysAgo: 3), leftoversEaten(daysAgo: 2), log(soup, daysAgo: 1)]
        #expect(ideas(meals: [stew, soup], logs: logs).first?.title == "Soup")
    }

    @Test func leftoversSayHowOldTheyAre() throws {
        let stew = dish("Stew", nil)
        let idea = try #require(ideas(meals: [stew], logs: [log(stew, daysAgo: 2)]).first)
        #expect(idea.why.hasPrefix("Leftover Stew from "))
        #expect(idea.why.hasSuffix(" · 2 days old"))
        #expect(idea.minutes == 10)
        #expect(idea.isEstimate)
        #expect(ideas(meals: [stew], logs: [log(stew, daysAgo: 1)]).first?.why == "Leftover Stew from yesterday")
    }

    @Test func leftoversOfADishTheLibraryLacksStillShowUnchecked() throws {
        let gone = dish("Pot roast", nil)
        let allergies = [MemberAllergies(memberID: ana, firstName: "Ana", allergens: [.milk])]
        let idea = try #require(ideas(logs: [log(gone, daysAgo: 1)], allergies: allergies).first)
        #expect(idea.title == "Pot roast")
        #expect(idea.allergies.flags.isEmpty)
        #expect(idea.allergies.note != nil)
    }

    // MARK: - Freezer

    @Test func theFreezerOffersOneOfEachDishOldestFirst() throws {
        let chili = dish("Chili", nil)
        let (older, newer) = (frozen(chili, daysAgo: 30), frozen(chili, daysAgo: 5))
        let ideas = ideas(meals: [chili], freezer: [newer, older])
        #expect(kinds(ideas).filter { $0 == "freezer" }.count == 1)
        guard case .freezer(let item) = try #require(ideas.first).kind else {
            Issue.record("expected the freezer first")
            return
        }
        #expect(item == older)
        #expect(ideas[0].minutes == 30)
        #expect(ideas[0].isEstimate)
        #expect(ideas[0].why.hasSuffix(" · around 30 min"))
    }

    @Test func underThirtyMinutesTheFreezerMovesDown() {
        let (chili, pizza, eggs) = (dish("Chili", nil), backup("Pizza"), dish("Eggs"))
        #expect(kinds(ideas(minutes: 30, meals: [chili, pizza, eggs], freezer: [frozen(chili)]))
            == ["freezer", "backup", "dish"])
        #expect(kinds(ideas(minutes: 20, meals: [chili, pizza, eggs], freezer: [frozen(chili)], count: 4))
            == ["backup", "dish", "freezer", "takeout"])
    }

    @Test func aDishInTheFreezerIsntAlsoABackup() {
        let pizza = backup("Pizza")
        #expect(ideas(meals: [pizza], freezer: [frozen(pizza)]).filter { $0.title == "Pizza" }.count == 1)
    }

    // MARK: - Equipment and trial

    @Test func missingEquipmentAndTrialDishesAreLeftOut() {
        var settings = HouseholdSettings()
        settings.missingEquipment = [.airFryer]
        let meals = [dish("Air fryer wings"), dish("New thing", status: .trial)]
        #expect(kinds(ideas(meals: meals, settings: settings)) == ["takeout", "freezer_raid", "fend_for_yourselves"])
    }

    // MARK: - Choosing

    @Test func eachIdeaKnowsWhatItBecomes() throws {
        let (stew, chili, pizza, eggs) = (dish("Stew", nil), dish("Chili", nil), backup("Pizza"), dish("Eggs"))
        let item = frozen(chili)
        let ideas = ideas(meals: [stew, chili, pizza, eggs], freezer: [item], logs: [log(stew, daysAgo: 1)], count: 5)
        #expect(ideas.map(\.pollChoice) == [.quickPick(.leftovers), .freezer(item.id), .meal(pizza.id), .meal(eggs.id),
                                            .quickPick(.takeout)])
        #expect(ideas[0].swapChoice == .quickPick(.leftovers))
        #expect(ideas[1].swapChoice == .freezer(item, reason: FreezerStash.reason(madeOn: item.madeOn, today: today)))
        #expect(ideas[2].swapChoice == .meal(id: pizza.id, name: "Pizza"))
        #expect(ideas[3].swapChoice == .meal(id: eggs.id, name: "Eggs"))
        #expect(ideas[4].swapChoice == .quickPick(.takeout))
        #expect(Set(ideas.map(\.id)).count == ideas.count)
    }

    // MARK: - When it's offered

    @Test func offeredTonightWhenNothingsLoggedAndSomeoneIsHome() {
        let night = tonight()
        #expect(TonightRescue.offers(night: night, logged: false, isAway: false, today: today))
        #expect(!TonightRescue.offers(night: night, logged: true, isAway: false, today: today))
        #expect(!TonightRescue.offers(night: night, logged: false, isAway: true, today: today))
        #expect(!TonightRescue.offers(night: night, logged: false, isAway: false, today: today.adding(days: -1)))
        let nobodyHome = tonight(attendance: [ana: false, ben: false])
        #expect(!TonightRescue.offers(night: nobodyHome, logged: false, isAway: false, today: today))
        #expect(TonightRescue.offers(night: tonight(attendance: [:]), logged: false, isAway: false, today: today))
    }

    // MARK: - Start cooking's minutes

    private func cookTime(_ meal: LibraryMeal) -> String? {
        StartCooking.minutes(for: meal).map { $0.isEstimate ? "~\($0.minutes)" : "\($0.minutes)" }
    }

    @Test func startCookingMinutesComeFromTheDishThenItsTags() {
        #expect(cookTime(dish("Lasagna", 45, tags: [.quick])) == "45")
        #expect(cookTime(dish("Tacos", nil, tags: [.quick])) == "~30")
        #expect(cookTime(dish("Chili", nil, tags: [.slowCooker])) == "~480")
        #expect(cookTime(dish("Crockpot ribs", nil)) == "~480")
        #expect(cookTime(dish("Lasagna", nil)) == nil)
    }

    @Test func theNudgeStillGoesByThoseMinutes() {
        let settings = HouseholdSettings()
        let night = tonight()
        let timed = StartCooking.nudge(for: dish("Lasagna", 45), on: night, settings: settings, today: today,
                                       minuteNow: 0)
        #expect(timed?.cookMinutes == 45)
        #expect(timed?.isEstimate == false)
        let guessed = StartCooking.nudge(for: dish("Tacos", nil, tags: [.quick]), on: night, settings: settings,
                                         today: today, minuteNow: 0)
        #expect(guessed?.cookMinutes == 30)
        #expect(guessed?.isEstimate == true)
        #expect(StartCooking.nudge(for: dish("Lasagna", nil), on: night, settings: settings, today: today,
                                   minuteNow: 0) == nil)
    }
}
