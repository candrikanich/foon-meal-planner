import Foundation
import Synchronization
import Testing
@testable import Foon

/// Kitchen equipment (#55): dishes that usually use what the household doesn't have drop out of what Foon picks on its
/// own, never out of what the family asked for, and they stay within reach in Swap and Search.
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

    // MARK: What a dish usually uses

    @Test(arguments: [
        ("Air fryer wings", KitchenEquipment.airFryer), ("Air-fried wings", .airFryer), ("Airfryer fries", .airFryer),
        ("Airfried wings", .airFryer),
        ("Instant Pot chili", .instantPot), ("InstantPot ribs", .instantPot), ("Instapot beans", .instantPot),
        ("Pressure cooker beans", .instantPot),
        ("Crock pot roast", .slowCooker), ("Crockpot chili", .slowCooker), ("Slow cooker ribs", .slowCooker),
        ("Slowcooker ribs", .slowCooker), ("Slow Cook pork", .slowCooker), ("Slow-cooked pork", .slowCooker),
        ("Grilled salmon", .grill), ("Chicken on the grill", .grill), ("Steak from the grill", .grill),
        ("Mixed grill", .grill),
    ] as [(String, KitchenEquipment)])
    func theNameSaysWhatADishUses(name: String, uses: KitchenEquipment) {
        #expect(DishTraits(name: name).equipment == [uses])
    }

    @Test(arguments: ["Grilled cheese", "Grilled ham and cheese", "Grilled PB&J", "Grilled PB and J",
                      "Pan-grilled chicken", "Instant ramen", "Pot roast", "Air Force lasagna", "Tacos"])
    func otherNamesUseNothing(name: String) {
        #expect(DishTraits(name: name).equipment.isEmpty)
    }

    @Test func tagsSayWhatADishUses() {
        #expect(DishTraits(name: "Carne asada", tags: [.grill]).equipment == [.grill])
        #expect(DishTraits(name: "Chili", tags: [.slowCooker, .leftovers]).equipment == [.slowCooker])
    }

    @Test func missingEquipmentNamesOnlyWhatThisDishUses() {
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

    @Test func aDishUsingWhatTheyDontHaveIsLeftOut() {
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

    @Test func aNightOnlyThoseDishesCouldFillSaysNothingFits() {
        let grilled = (0..<7).map { LibraryMeal.fixture(name: "Grill night \($0)", tags: [.grill]) }
        let inputs = PlanningInputs(nights: nights(), meals: grilled, settings: noGrill)
        for seed in seeds {
            let draft = BuildMyWeek.draft(inputs, seed: seed)
            #expect(draft.allSatisfy { $0.pick == nil && $0.reason == .nothingFits })
        }
    }

    @Test func otherDishesFillWhatTheyCanAndTheRestSaysNothingFits() {
        let grilled = (0..<3).map { LibraryMeal.fixture(name: "Grill night \($0)", tags: [.grill]) }
        let plain = plainDishes(4)
        let inputs = PlanningInputs(nights: nights(), meals: plain + grilled, settings: noGrill)
        for seed in seeds {
            let draft = BuildMyWeek.draft(inputs, seed: seed)
            #expect(Set(draft.compactMap(\.pick?.mealID)) == Set(plain.map(\.id)))
            #expect(draft.filter { $0.reason == .nothingFits }.count == 3)
        }
    }

    @Test func aTrialDishFillsANightButADishTheyCantMakeDoesnt() {
        let trial = LibraryMeal.fixture(name: "Something new", status: .trial)
        let trialGrill = LibraryMeal.fixture(name: "New burgers", tags: [.grill], status: .trial)
        let grilled = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let inputs = PlanningInputs(nights: nights(count: 2), meals: [trial, trialGrill, grilled], settings: noGrill)
        for seed in seeds {
            let draft = BuildMyWeek.draft(inputs, seed: seed)
            #expect(draft.compactMap(\.pick?.mealID) == [trial.id])
            #expect(draft[1].reason == .nothingFits)
        }
    }

    @Test func theSameSeedGivesTheSameWeekWithEquipmentSet() {
        let library = plainDishes(5) + [.fixture(name: "Burgers", tags: [.grill]), .fixture(name: "Chili", tags: [.slowCooker])]
        let inputs = PlanningInputs(nights: nights(), meals: library, settings: noGrill)
        let shuffled = PlanningInputs(nights: inputs.nights.reversed(), meals: library.reversed(), settings: noGrill)
        for seed in seeds {
            #expect(BuildMyWeek.draft(inputs, seed: seed) == BuildMyWeek.draft(shuffled, seed: seed))
        }
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

    @Test func shuffleMovesOffADishTheyCantMake() {
        let current = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let plain = LibraryMeal.fixture(name: "Plain")
        var week = nights(count: 1)
        week[0].mealID = current.id
        let inputs = PlanningInputs(nights: week, meals: [current, plain], settings: noGrill)
        #expect(BuildMyWeek.shuffle(night: week[0].id, inputs: inputs, seed: 1)?.pick == .meal(plain.id))
    }

    @Test func shuffleStillChangesADishTheyCantMakeWhenOnlyOthersLikeItAreLeft() {
        let current = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let other = LibraryMeal.fixture(name: "Steak", tags: [.grill])
        var week = nights(count: 1)
        week[0].mealID = current.id
        let inputs = PlanningInputs(nights: week, meals: [current, other], settings: noGrill)
        #expect(BuildMyWeek.shuffle(night: week[0].id, inputs: inputs, seed: 1)?.pick == .meal(other.id))
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

    @Test(arguments: [
        (KitchenEquipment.grill, MealTag.grill, "Usually uses a grill"),
        (.slowCooker, .slowCooker, "Usually uses a slow cooker"),
    ] as [(KitchenEquipment, MealTag, String)])
    func aDishTheyMayNotBeAbleToMakeSaysSoHonestly(equipment: KitchenEquipment, tag: MealTag, text: String) {
        let meal = LibraryMeal.fixture(name: "Dish", tags: [tag])
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [],
                                   settings: settings(missing: [equipment])) == [.equipment(text)])
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], settings: settings()).isEmpty)
    }

    @Test func theOtherEquipmentReadsTheSameWay() {
        #expect(KitchenEquipment.airFryer.usuallyUsesText == "Usually uses an air fryer")
        #expect(KitchenEquipment.instantPot.usuallyUsesText == "Usually uses an Instant Pot")
    }
}

/// Fill runs through the store, which locks what's already planned before drafting.
@MainActor
struct KitchenFillTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)
    private let ann = Member.fixture(firstName: "Ann", guardian: true, role: .planner)

    @Test func fillingRemainingNightsLeavesThoseDishesOutAndKeepsOnePlannedOnPurpose() async {
        var settings = HouseholdSettings()
        settings.newDishesPerWeek = 0
        settings.leftoverNights = 0
        settings.missingEquipment = [.grill]
        let steak = LibraryMeal.fixture(name: "Steak", tags: [.grill])
        let burgers = LibraryMeal.fixture(name: "Burgers", tags: [.grill])
        let plain = LibraryMeal.fixture(name: "Plain")
        var week = Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<3).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [ann.id: true])
        })
        week.nights[0].mealID = steak.id
        week.nights[0].mealName = steak.name
        let existing = week
        let sent = Mutex<[NightUpdate]>([])
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing }, setNights: { _, updates in sent.withLock { $0 = updates } }
        ), today: { [sunday] in sunday })
        await store.load(settings: settings)
        let context = PlanningContext(meals: [steak, burgers, plain], history: [], settings: settings, members: [ann])
        await store.fillRemaining { context }
        #expect(store.week?.nights[0].mealID == steak.id)
        #expect(store.week?.nights.compactMap(\.mealID).sorted { $0.uuidString < $1.uuidString }
            == [steak.id, plain.id].sorted { $0.uuidString < $1.uuidString })
        #expect(!sent.withLock { $0 }.contains { $0.nightID == existing.nights[0].id })
    }
}

/// How `households.settings` carries the equipment list and the nudge's switch.
@MainActor
struct KitchenSettingsTests {
    private let me = UUID()

    private func decode(_ json: String) throws -> HouseholdSettings {
        try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
    }

    private func sentJSON(_ kitchen: HouseholdSettings.Kitchen) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(kitchen)) as? [String: Any])
    }

    @Test func aHouseholdThatSaidNothingHasEverything() throws {
        let settings = try decode("{}")
        #expect(settings.missingEquipment.isEmpty)
        #expect(settings.showsStartCooking)
    }

    @Test func kitchenValuesRoundTrip() throws {
        var settings = HouseholdSettings()
        settings.missingEquipment = [.grill, .instantPot]
        settings.showsStartCooking = false
        let back = try JSONDecoder().decode(HouseholdSettings.self, from: JSONEncoder().encode(settings.kitchen))
        #expect(back.missingEquipment == [.grill, .instantPot])
        #expect(!back.showsStartCooking)
    }

    @Test func turningEverythingBackOnIsSent() throws {
        // The server merges keys, so leaving this out would keep the old list.
        #expect((try sentJSON(HouseholdSettings().kitchen)["missing_equipment"] as? [String]) == [])
    }

    @Test func aKitchenSaveSendsOnlyItsOwnKeys() throws {
        #expect(Set(try sentJSON(HouseholdSettings().kitchen).keys) == ["missing_equipment", "start_cooking_nudge"])
    }

    /// Settings saves merge whatever they send. A stale copy changing dinner time mustn't undo another planner's list.
    @Test func otherSettingsSavesLeaveTheKitchenAlone() throws {
        var settings = HouseholdSettings()
        settings.missingEquipment = [.grill]
        settings.showsStartCooking = false
        let encoded = try JSONEncoder().encode(settings)
        let keys = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        #expect(!keys.contains("missing_equipment"))
        #expect(!keys.contains("start_cooking_nudge"))
        #expect(keys.contains("dinner_time"))
    }

    @Test func aValueFromANewerAppIsIgnoredHereButSurvivesAKitchenSave() throws {
        var settings = try decode(#"{"missing_equipment": ["grill", "wood_oven"]}"#)
        #expect(settings.missingEquipment == [.grill])
        #expect((try sentJSON(settings.kitchen)["missing_equipment"] as? [String]) == ["grill", "wood_oven"])
        settings.missingEquipment.remove(.grill)
        #expect((try sentJSON(settings.kitchen)["missing_equipment"] as? [String]) == ["wood_oven"])
    }

    @Test func aBadListCountsAsNothing() throws {
        #expect(try decode(#"{"missing_equipment": "grill"}"#).missingEquipment.isEmpty)
    }

    @Test func theStoreSendsOnlyTheKitchenAndKeepsTheRestOfWhatItHas() async {
        let me = me
        var saved = HouseholdSettings()
        saved.dinnerTime = "17:30"
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me, settings: saved)
        let wholeSaves = Mutex(0)
        let kitchens = Mutex<[HouseholdSettings.Kitchen]>([])
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            updateSettings: { _, _ in wholeSaves.withLock { $0 += 1 } },
            updateKitchen: { _, kitchen in kitchens.withLock { $0.append(kitchen) } }
        ), deviceTimeZone: { "America/Chicago" })
        await store.load()
        let before = wholeSaves.withLock { $0 }
        var stale = HouseholdSettings()
        stale.missingEquipment = [.grill]
        #expect(await store.updateKitchen(stale))
        #expect(wholeSaves.withLock { $0 } == before)
        #expect(kitchens.withLock { $0 } == [stale.kitchen])
        #expect(store.household?.planningSettings.missingEquipment == [.grill])
        #expect(store.household?.planningSettings.dinnerTime == "17:30", "only the kitchen changes on this device")
    }

    @Test func aFailedKitchenSaveLeavesTheToggleAndSaysSo() async {
        let me = me
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household }, updateKitchen: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        var changed = HouseholdSettings()
        changed.missingEquipment = [.grill]
        #expect(await !store.updateKitchen(changed))
        #expect(store.household?.planningSettings.missingEquipment.isEmpty == true)
        #expect(store.errorMessage != nil)
    }

    @Test func aStaleSettingsSaveKeepsTheKitchenOnThisDevice() async {
        let me = me
        var saved = HouseholdSettings()
        saved.missingEquipment = [.grill]
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me, settings: saved)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }))
        await store.load()
        var stale = HouseholdSettings()
        stale.dinnerTime = "19:00"
        #expect(await store.updateSettings(stale))
        #expect(store.household?.planningSettings.dinnerTime == "19:00")
        #expect(store.household?.planningSettings.missingEquipment == [.grill])
    }
}

/// "Start cooking at 5:45 PM for 6:30 PM dinner" (#55).
struct StartCookingTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)
    private let enUS = Locale(identifier: "en_US")
    private let nora = UUID()
    /// 8:00 in the morning: before any start in these tests unless one says otherwise.
    private let morning = 8 * 60

    private func night(_ day: CalendarDay? = nil, time: String? = "18:30:00", attendance: [UUID: Bool] = [:]) -> WeekNight {
        WeekNight(id: UUID(), date: day ?? today, effort: .normal, dinnerTime: time, mealID: UUID(), mealName: "Dish",
                  quickPick: nil, locked: false, attendance: attendance)
    }

    /// The system's time format puts a narrow space before PM.
    private func text(_ nudge: StartCooking?, locale: Locale? = nil) -> String? {
        nudge?.text(locale: locale ?? enUS).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func nudge(_ meal: LibraryMeal, _ night: WeekNight? = nil, settings: HouseholdSettings = HouseholdSettings(),
                       at minute: Int? = nil) -> StartCooking? {
        StartCooking.nudge(for: meal, on: night ?? self.night(), settings: settings, today: today,
                           minuteNow: minute ?? morning)
    }

    private func timed(_ minutes: Int, name: String = "Lasagna", tags: [MealTag] = [],
                       prepSteps: [PrepStep] = []) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: name, tags: tags, prepSteps: prepSteps)
        meal.cookMinutes = minutes
        return meal
    }

    private var chili: LibraryMeal {
        .fixture(name: "Chili", tags: [.slowCooker], prepSteps: [PrepStep(step: "Start the slow cooker", leadHours: 8)])
    }

    // MARK: Where the time comes from

    @Test func aDishsOwnTimeSaysAt() {
        #expect(text(nudge(timed(45))) == "Start cooking at 5:45 PM for 6:30 PM dinner")
    }

    @Test func aDishsOwnTimeBeatsItsTags() {
        #expect(nudge(timed(45, tags: [.quick]))?.cookMinutes == 45)
    }

    @Test(arguments: [
        ([MealTag.quick], 30), ([.slowCooker], 480), ([.slowCooker, .quick], 480),
    ] as [([MealTag], Int)])
    func quickAndSlowCookerDishesGetAnEstimate(tags: [MealTag], minutes: Int) {
        let nudge = nudge(.fixture(name: "Dish", tags: tags))
        #expect(nudge?.cookMinutes == minutes)
        #expect(nudge?.isEstimate == true)
    }

    @Test(arguments: ["Crockpot chili", "Slow cooker ribs", "Slow-cooked pork"])
    func aNameSayingSlowCookerCounts(name: String) {
        #expect(nudge(.fixture(name: name))?.cookMinutes == 480)
    }

    @Test(arguments: [[MealTag.leftovers], [.grill], [.thawFirst], []] as [[MealTag]])
    func everythingElseGetsNoNudgeUntilSomeoneSetsATime(tags: [MealTag]) {
        #expect(nudge(.fixture(name: "Lasagna", tags: tags)) == nil)
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
        #expect(nudge(timed(30), night(time: "soon")) == nil)
    }

    @Test func aTwentyFourHourLocaleReadsThatWay() {
        #expect(text(nudge(timed(45)), locale: Locale(identifier: "en_GB")) == "Start cooking at 17:45 for 18:30 dinner")
    }

    // MARK: The midnight boundary

    @Test func aStartAtMidnightStillShows() {
        let nudge = nudge(timed(30), night(time: "00:30"), at: 0)
        #expect(nudge?.startMinute == 0)
        #expect(text(nudge) == "Start cooking at 12:00 AM for 12:30 AM dinner")
    }

    @Test func aStartTheDayBeforeGetsNoNudge() {
        #expect(nudge(timed(31), night(time: "00:30"), at: 0) == nil)
        #expect(nudge(timed(20 * 60)) == nil)
    }

    // MARK: Whether it can still be followed

    @Test func tonightsStartThatHasPassedIsHidden() {
        #expect(nudge(chili, at: 15 * 60) == nil, "at 3pm nobody can start at 10:30 AM")
    }

    @Test func tonightsStartShowsUpToTheMinute() {
        #expect(nudge(timed(30), at: 18 * 60) != nil)
        #expect(nudge(timed(30), at: 18 * 60 + 1) == nil)
    }

    @Test func afterDinnerItsHidden() {
        #expect(nudge(timed(30), at: 20 * 60) == nil)
    }

    @Test func anotherNightDoesntCareWhatTimeItIsNow() {
        #expect(nudge(chili, night(today.adding(days: 1)), at: 23 * 60) != nil)
    }

    @Test func aPassedStartLetsThePrepChipComeBack() {
        let badges = NightBadges.badges(meal: chili, library: [chili], allergies: [], home: [],
                                        start: nudge(chili, at: 15 * 60))
        #expect(badges == [.prep("Start the slow cooker · 8 hours ahead")])
    }

    @Test func theCurrentMinuteIsTheHouseholds() {
        var settings = HouseholdSettings()
        settings.timeZone = "America/Chicago"
        // 2026-11-03 20:15 UTC is 2:15 PM in Chicago, whatever this device's zone.
        let now = Date(timeIntervalSince1970: 1_793_736_900)
        #expect(settings.minuteOfDay(now: now) == 14 * 60 + 15)
    }

    @Test func nobodyHomeGetsNone() {
        #expect(nudge(timed(30), night(attendance: [nora: false])) == nil)
        #expect(nudge(timed(30), night(attendance: [nora: true])) != nil)
        #expect(nudge(timed(30), night(attendance: [:])) != nil, "no rows yet isn't nobody home")
    }

    @Test func aHouseholdCanTurnItOff() {
        var settings = HouseholdSettings()
        settings.showsStartCooking = false
        #expect(nudge(timed(30), settings: settings) == nil)
    }

    @Test func pastNightsGetNone() {
        #expect(nudge(timed(30), night(today.adding(days: -1))) == nil)
        #expect(nudge(timed(30), night(today.adding(days: 1))) != nil)
    }

    // MARK: Badges

    @Test func itJoinsTheNightsBadges() {
        let meal = LibraryMeal.fixture(name: "Tacos", tags: [.quick])
        let nudge = nudge(meal)
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? "")])
    }

    @Test func theSlowCookerStepGivesWay() {
        let nudge = nudge(chili)
        #expect(NightBadges.badges(meal: chili, library: [chili], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? "")])
        #expect(NightBadges.badges(meal: chili, library: [chili], allergies: [], home: [])
            == [.prep("Start the slow cooker · 8 hours ahead")])
    }

    @Test func aDishsOwnTimeWinsOverADifferentSlowCookerStep() {
        let meal = timed(6 * 60, name: "Chili", tags: [.slowCooker],
                         prepSteps: [PrepStep(step: "Start the slow cooker", leadHours: 8)])
        let nudge = nudge(meal)
        #expect(nudge?.cookMinutes == 360)
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? "")])
    }

    @Test func aMarinateWithTheSameLeadStillShows() {
        let meal = timed(60, name: "Kebabs", prepSteps: [PrepStep(step: "Marinate the chicken", leadHours: 1)])
        let nudge = nudge(meal)
        #expect(NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], start: nudge)
            == [.startCooking(nudge?.text() ?? ""), .prep("Marinate the chicken · 1 hour ahead")])
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
                                         .equipment("Usually uses a grill")], isLocked: false)
        let summary = DayCardText.accessibilitySummary(card, today: today)
        #expect(summary.contains("Start cooking at 5:45 PM for 6:30 PM dinner"))
        #expect(summary.contains("Usually uses a grill"))
    }

    // MARK: The dish's time

    @Test func theDraftKeepsTheTime() throws {
        var draft = MealDraft(timed(90))
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
