import Foundation
import Testing
@testable import Foon

/// Kitchen equipment (#55): dishes that need what the household doesn't have drop out of suggestions, never out of
/// what the family asked for, and never at the cost of an empty night.
struct KitchenEquipmentTests {
    private let sunday = CalendarDay(year: 2026, month: 4, day: 5)
    private let nora = UUID()
    private let seeds = UInt64(0)..<60

    private var noGrill: HouseholdSettings { settings(missing: [.grill]) }

    private func settings(missing: Set<KitchenEquipment> = []) -> HouseholdSettings {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.missingEquipment = missing
        return settings
    }

    private func nights(count: Int = 7) -> [PlanningNight] {
        (0..<count).map { PlanningNight(id: UUID(), date: sunday.adding(days: $0), attendance: [nora: true]) }
    }

    private func plainDishes(_ count: Int = 7) -> [LibraryMeal] {
        (0..<count).map { .fixture(name: "Dish \($0)") }
    }

    // MARK: What a dish needs

    @Test(arguments: [
        ("Air fryer wings", KitchenEquipment.airFryer), ("Air-fried wings", .airFryer), ("Airfryer fries", .airFryer),
        ("Instant Pot chili", .instantPot), ("Instapot beans", .instantPot), ("Pressure cooker beans", .instantPot),
        ("Crock pot roast", .slowCooker), ("Crockpot chili", .slowCooker), ("Slow cooker ribs", .slowCooker),
        ("Grilled salmon", .grill), ("Chicken on the grill", .grill),
    ] as [(String, KitchenEquipment)])
    func theNameSaysWhatADishNeeds(name: String, needs: KitchenEquipment) {
        #expect(DishTraits(name: name).equipment == [needs])
    }

    @Test(arguments: ["Grilled cheese", "Instant ramen", "Pot roast", "Air Force lasagna", "Tacos"])
    func otherNamesNeedNothing(name: String) {
        #expect(DishTraits(name: name).equipment.isEmpty)
    }

    @Test func tagsSayWhatADishNeeds() {
        #expect(DishTraits(name: "Carne asada", tags: [.grill]).equipment == [.grill])
        #expect(DishTraits(name: "Chili", tags: [.slowCooker, .leftovers]).equipment == [.slowCooker])
    }

    @Test func missingEquipmentNamesOnlyWhatThisDishNeeds() {
        let settings = settings(missing: [.grill, .airFryer])
        #expect(settings.missingEquipment(for: .fixture(name: "Burgers", tags: [.grill])) == [.grill])
        #expect(settings.missingEquipment(for: .fixture(name: "Chili", tags: [.slowCooker])).isEmpty)
    }

    // MARK: Build my week

    @Test func saidNothingKeepsEveryDish() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let inputs = PlanningInputs(nights: nights(), meals: plainDishes(6) + [grilled], settings: settings())
        #expect(seeds.allSatisfy { seed in
            BuildMyWeek.draft(inputs, seed: seed).contains { $0.pick == .meal(grilled.id) }
        })
    }

    @Test func aDishNeedingWhatTheyDontHaveIsLeftOut() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let inputs = PlanningInputs(nights: nights(), meals: plainDishes() + [grilled], settings: noGrill)
        for seed in seeds {
            let draft = BuildMyWeek.draft(inputs, seed: seed)
            #expect(!draft.contains { $0.pick == .meal(grilled.id) })
            #expect(draft.allSatisfy { $0.pick != nil })
        }
    }

    @Test func otherEquipmentIsUntouched() {
        let chili = LibraryMeal.fixture(name: "Chili", tags: [.slowCooker])
        let inputs = PlanningInputs(nights: nights(), meals: plainDishes(6) + [chili], settings: noGrill)
        #expect(seeds.allSatisfy { seed in
            BuildMyWeek.draft(inputs, seed: seed).contains { $0.pick == .meal(chili.id) }
        })
    }

    @Test func itNeverEmptiesANightThatADishCouldFill() {
        let grilled = (0..<7).map { LibraryMeal.fixture(name: "Grill night \($0)", tags: [.grill]) }
        let inputs = PlanningInputs(nights: nights(), meals: grilled, settings: noGrill)
        let draft = BuildMyWeek.draft(inputs, seed: 1)
        #expect(draft.allSatisfy { $0.pick?.mealID != nil })
        #expect(!draft.contains { $0.reason == .nothingFits })
    }

    @Test func aLastResortOnlyFillsWhatOtherDishesCouldnt() {
        let grilled = (0..<3).map { LibraryMeal.fixture(name: "Grill night \($0)", tags: [.grill]) }
        let plain = plainDishes(4)
        let inputs = PlanningInputs(nights: nights(), meals: plain + grilled, settings: noGrill)
        for seed in seeds {
            let picked = Set(BuildMyWeek.draft(inputs, seed: seed).compactMap(\.pick?.mealID))
            #expect(Set(plain.map(\.id)).isSubset(of: picked))
        }
    }

    @Test func otherFiltersStillHoldForALastResort() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        var rushed = nights(count: 1)
        rushed[0].effort = .rushed
        let inputs = PlanningInputs(nights: rushed, meals: [grilled], settings: noGrill)
        #expect(BuildMyWeek.draft(inputs, seed: 1)[0].reason == .nothingFits)
    }

    @Test func aRequestStillLands() {
        let grilled = LibraryMeal.fixture(name: "Steak", tags: [.grill])
        let week = nights()
        let inputs = PlanningInputs(nights: week, meals: plainDishes() + [grilled], settings: noGrill,
                                    requests: [DatedRequest(mealID: grilled.id, date: week[2].date, requesterID: nora)])
        let draft = BuildMyWeek.draft(inputs, seed: 1)
        #expect(draft[2].pick == .meal(grilled.id))
        #expect(draft[2].locks)
    }

    @Test func aWantedRequestStillLands() {
        let grilled = LibraryMeal.fixture(name: "Steak", tags: [.grill])
        let inputs = PlanningInputs(nights: nights(), meals: plainDishes() + [grilled], settings: noGrill,
                                    wanted: [WantedRequest(mealID: grilled.id, requesterID: nora, wanters: [nora])])
        #expect(BuildMyWeek.draft(inputs, seed: 1).contains { $0.pick == .meal(grilled.id) })
    }

    @Test func aTraditionStillLands() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let week = nights()
        let inputs = PlanningInputs(
            nights: week, meals: plainDishes() + [grilled], settings: noGrill,
            traditions: [Tradition(weekday: week[3].date.isoWeekday, pick: .meal(grilled.id), name: "Burger night")])
        #expect(BuildMyWeek.draft(inputs, seed: 1)[3].pick == .meal(grilled.id))
    }

    @Test func aLockedNightStays() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        var week = nights()
        week[1].locked = true
        week[1].mealID = grilled.id
        let inputs = PlanningInputs(nights: week, meals: plainDishes() + [grilled], settings: noGrill)
        #expect(BuildMyWeek.draft(inputs, seed: 1)[1].pick == .meal(grilled.id))
    }

    // MARK: Shuffle

    @Test func shuffleLeavesItOutWhileAnythingElseFits() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let current = LibraryMeal.fixture(name: "Current")
        var week = nights(count: 1)
        week[0].mealID = current.id
        let inputs = PlanningInputs(nights: week, meals: [current, grilled, .fixture(name: "Other")], settings: noGrill)
        for seed in seeds {
            #expect(BuildMyWeek.shuffle(night: week[0].id, inputs: inputs, seed: seed)?.pick != .meal(grilled.id))
        }
    }

    @Test func shuffleWontTradeADishTheyCanMakeForOneTheyCant() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let current = LibraryMeal.fixture(name: "Current")
        var week = nights(count: 1)
        week[0].mealID = current.id
        let inputs = PlanningInputs(nights: week, meals: [current, grilled], settings: noGrill)
        #expect(BuildMyWeek.shuffle(night: week[0].id, inputs: inputs, seed: 1) == nil)
    }

    @Test func pickForMeTakesItOnAnEmptyNightWhenNothingElseFits() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let week = nights(count: 1)
        let inputs = PlanningInputs(nights: week, meals: [grilled], settings: noGrill)
        #expect(BuildMyWeek.shuffle(night: week[0].id, inputs: inputs, seed: 1)?.pick == .meal(grilled.id))
    }

    // MARK: Swap

    @Test func swapLeavesItOutWhenThereAreEnoughOthers() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let week = nights(count: 1)
        let inputs = PlanningInputs(nights: week, meals: plainDishes(3) + [grilled], settings: noGrill)
        for seed in seeds {
            let picks = BuildMyWeek.suggestions(night: week[0].id, inputs: inputs, seed: seed)
            #expect(picks.count == 3)
            #expect(!picks.contains { $0.mealID == grilled.id })
        }
    }

    @Test func swapStillOffersItAfterEverythingElse() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let plain = LibraryMeal.fixture(name: "Plain")
        let week = nights(count: 1)
        let inputs = PlanningInputs(nights: week, meals: [plain, grilled], settings: noGrill)
        let picks = BuildMyWeek.suggestions(night: week[0].id, inputs: inputs, seed: 1)
        #expect(picks.map(\.mealID) == [plain.id, grilled.id])
    }

    @Test func loggingAPastNightIgnoresEquipment() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let week = nights(count: 2)
        let inputs = PlanningInputs(nights: week, meals: plainDishes(3) + [grilled], settings: noGrill,
                                    today: week[1].date)
        #expect(seeds.contains { seed in
            BuildMyWeek.suggestions(night: week[0].id, inputs: inputs, seed: seed).contains { $0.mealID == grilled.id }
        })
    }

    @Test func aNoteOnlyWhenADishInRotationIsSetAside() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let archived = LibraryMeal.fixture(name: "Old burgers", tags: [.grill], status: .archived)
        #expect(noGrill.setsAsideDishes(in: [grilled]))
        #expect(!noGrill.setsAsideDishes(in: [archived, .fixture(name: "Plain")]))
        #expect(!settings().setsAsideDishes(in: [grilled]))
    }

    // MARK: Badges

    @Test func aDishTheyCantMakeSaysSo() {
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        #expect(NightBadges.badges(meal: grilled, library: [grilled], allergies: [], home: [], settings: noGrill)
            == [.equipment("Needs a grill")])
        #expect(NightBadges.badges(meal: grilled, library: [grilled], allergies: [], home: [], settings: settings())
            .isEmpty)
    }
}

/// How `households.settings` carries the equipment list and the nudge's switch.
struct KitchenSettingsTests {
    private func decode(_ json: String) throws -> HouseholdSettings {
        try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
    }

    @Test func aHouseholdThatSaidNothingHasEverything() throws {
        let settings = try decode("{}")
        #expect(settings.missingEquipment.isEmpty)
        #expect(settings.showsStartCooking)
    }

    @Test func savedValuesRoundTrip() throws {
        var settings = HouseholdSettings()
        settings.missingEquipment = [.grill, .instantPot]
        settings.showsStartCooking = false
        let back = try JSONDecoder().decode(HouseholdSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.missingEquipment == [.grill, .instantPot])
        #expect(!back.showsStartCooking)
    }

    @Test func turningEverythingBackOnIsSent() throws {
        // The server merges keys, so leaving this out would keep the old list.
        let data = try JSONEncoder().encode(HouseholdSettings())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["missing_equipment"] as? [String]) == [])
    }

    @Test func aValueFromANewerAppIsIgnored() throws {
        #expect(try decode(#"{"missing_equipment": ["grill", "wood_oven"]}"#).missingEquipment == [.grill])
    }

    @Test func aBadListCountsAsNothing() throws {
        #expect(try decode(#"{"missing_equipment": "grill"}"#).missingEquipment.isEmpty)
    }
}

/// "Start cooking at 5:45 PM for 6:30 PM dinner" (#55).
struct StartCookingTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)
    private let enUS = Locale(identifier: "en_US")

    private func night(_ day: CalendarDay? = nil, time: String? = "18:30:00") -> WeekNight {
        WeekNight(id: UUID(), date: day ?? today, effort: .normal, dinnerTime: time, mealID: UUID(), mealName: "Dish",
                  quickPick: nil, locked: false, attendance: [:])
    }

    /// The system's time format puts a narrow space before PM.
    private func text(_ nudge: StartCooking?) -> String? {
        nudge?.text(locale: enUS).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func nudge(_ meal: LibraryMeal, _ night: WeekNight? = nil, settings: HouseholdSettings = HouseholdSettings())
        -> StartCooking? {
        StartCooking.nudge(for: meal, on: night ?? self.night(), settings: settings, today: today)
    }

    @Test func aDishsOwnTimeSaysAt() {
        var meal = LibraryMeal.fixture(name: "Lasagna")
        meal.cookMinutes = 45
        #expect(text(nudge(meal)) == "Start cooking at 5:45 PM for 6:30 PM dinner")
    }

    @Test func aDishsOwnTimeBeatsItsTags() {
        var meal = LibraryMeal.fixture(name: "Quick lasagna", tags: [.quick])
        meal.cookMinutes = 45
        #expect(nudge(meal)?.cookMinutes == 45)
    }

    @Test(arguments: [
        ([MealTag.quick], 30), ([.slowCooker], 480), ([.slowCooker, .quick], 480), ([.leftovers], 60), ([], 60),
    ] as [([MealTag], Int)])
    func withoutOneTagsGiveAnEstimate(tags: [MealTag], minutes: Int) {
        let nudge = nudge(.fixture(name: "Dish", tags: tags))
        #expect(nudge?.cookMinutes == minutes)
        #expect(nudge?.isEstimate == true)
    }

    @Test func anEstimateSaysAround() {
        #expect(text(nudge(.fixture(name: "Tacos", tags: [.quick]))) == "Start cooking around 6:00 PM for 6:30 PM dinner")
    }

    @Test func aNightWithNoTimeUsesTheHouseholds() {
        var settings = HouseholdSettings()
        settings.dinnerTime = "17:30"
        let nudge = nudge(.fixture(name: "Tacos", tags: [.quick]), night(time: nil), settings: settings)
        #expect(text(nudge) == "Start cooking around 5:00 PM for 5:30 PM dinner")
    }

    @Test func aTimeThatWontReadGetsNoNudge() {
        #expect(nudge(.fixture(name: "Tacos"), night(time: "soon")) == nil)
    }

    @Test func aStartBeforeMidnightGetsNoNudge() {
        var meal = LibraryMeal.fixture(name: "Smoked brisket")
        meal.cookMinutes = 20 * 60
        #expect(nudge(meal) == nil)
    }

    @Test func aHouseholdCanTurnItOff() {
        var settings = HouseholdSettings()
        settings.showsStartCooking = false
        #expect(nudge(.fixture(name: "Tacos"), settings: settings) == nil)
    }

    @Test func pastNightsGetNone() {
        #expect(nudge(.fixture(name: "Tacos"), night(today.adding(days: -1))) == nil)
        #expect(nudge(.fixture(name: "Tacos"), night(today.adding(days: 1))) != nil)
    }

    @Test func itJoinsTheNightsBadges() {
        let meal = LibraryMeal.fixture(name: "Tacos", tags: [.quick])
        let nudge = nudge(meal)
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? "")])
    }

    @Test func aPrepStepSayingTheSameThingGivesWay() {
        let chili = LibraryMeal.fixture(name: "Chili", tags: [.slowCooker],
                                        prepSteps: [PrepStep(step: "Start the slow cooker", leadHours: 8)])
        let nudge = nudge(chili)
        #expect(NightBadges.badges(meal: chili, library: [chili], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? "")])
        #expect(NightBadges.badges(meal: chili, library: [chili], allergies: [], home: [])
            == [.prep("Start the slow cooker · 8 hours ahead")])
    }

    @Test func aThawStepStillShows() {
        let roast = LibraryMeal.fixture(name: "Pot roast", tags: [.slowCooker, .thawFirst],
                                        prepSteps: [PrepStep(step: "Thaw the meat", leadHours: 24),
                                                    PrepStep(step: "Start the slow cooker", leadHours: 8)])
        let nudge = nudge(roast)
        #expect(NightBadges.badges(meal: roast, library: [roast], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? ""), .prep("Thaw the meat · 1 day ahead")])
    }

    @Test func theCardReadsItToVoiceOver() {
        let card = DayCardModel(date: today, effort: .normal, slot: .empty, attendance: [],
                                badges: [.startCooking("Start cooking at 5:45 PM for 6:30 PM dinner"),
                                         .equipment("Needs a grill")], isLocked: false)
        let summary = DayCardText.accessibilitySummary(card, today: today)
        #expect(summary.contains("Start cooking at 5:45 PM for 6:30 PM dinner"))
        #expect(summary.contains("Needs a grill"))
    }

    // MARK: The dish's time

    @Test func theDraftKeepsTheTime() throws {
        var meal = LibraryMeal.fixture(name: "Lasagna")
        meal.cookMinutes = 90
        var draft = MealDraft(meal)
        #expect(try draft.validated().cookMinutes == 90)
        draft.cookMinutes = nil
        #expect(try draft.validated().cookMinutes == nil)
        #expect(try MealDraft(newNamed: "Soup").validated().cookMinutes == nil)
    }

    @Test func theEditorOffersASavedTimeThatIsntOnTheList() {
        #expect(MealText.cookTimeChoices(including: 45) == MealText.cookTimeChoices(including: nil))
        #expect(MealText.cookTimeChoices(including: 37).contains(37))
        #expect(MealText.cookTimeChoices(including: 37).sorted() == MealText.cookTimeChoices(including: 37))
    }

    @Test func theEditorReadsTimesPlainly() {
        #expect(MealText.cookTime(minutes: 45, locale: enUS) == "45 minutes")
        #expect(MealText.cookTime(minutes: 60, locale: enUS) == "1 hour")
        #expect(MealText.cookTime(minutes: 90, locale: enUS) == "1 hour, 30 minutes")
    }
}
