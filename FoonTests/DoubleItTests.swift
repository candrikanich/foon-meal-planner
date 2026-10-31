import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let nora = UUID(), owen = UUID()
private let beef = UUID(), beans = UUID(), shells = UUID(), salsa = UUID()

private func night(_ offset: Int, meal: LibraryMeal? = nil, pick: QuickPick? = nil, locked: Bool = false,
                   leftoversFrom: UUID? = nil, stashItemID: UUID? = nil, effort: NightEffort = .normal,
                   home: [UUID: Bool] = [nora: true, owen: true]) -> WeekNight {
    WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: effort, dinnerTime: "18:00", mealID: meal?.id,
              mealName: meal?.name, quickPick: pick, locked: locked, attendance: home, leftoversFrom: leftoversFrom,
              stashItemID: stashItemID)
}

private func dish(_ name: String, _ lines: [(UUID, String, String?)], tags: [MealTag] = [],
                  sides: [MealSide] = []) -> LibraryMeal {
    var meal = LibraryMeal.fixture(name: name, tags: tags)
    meal.ingredients = lines.enumerated().map { index, line in
        MealIngredient(itemID: line.0, name: line.1, quantityText: line.2, position: index + 1)
    }
    meal.sides = sides
    return meal
}

private let chili = dish("Chili", [(beef, "ground beef", "1 1/2 lb"), (beans, "beans", "a big can"), (salsa, "milk", nil)])
private let tacos = dish("Tacos", [(beef, "ground beef", "1 lb"), (shells, "taco shells", "12")])

struct DoubleItListTests {
    @Test func aDoubledNightBuysTwiceItsAmountsAndSaysSo() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true)], library: [chili])
        #expect(lines.first { $0.itemID == beef }?.quantity == "3 lb (doubled)")
        #expect(lines.allSatisfy { $0.note == nil }, "the amount says it, and notes stay for allergies")
    }

    @Test func anAmountThatWontScaleStaysAsWrittenAndSaysToGetDouble() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true)], library: [chili])
        #expect(lines.first { $0.itemID == beans }?.quantity == "a big can (get double)")
        #expect(lines.first { $0.itemID == salsa }?.quantity == "get double")
    }

    @Test(arguments: ["1 to 2 lb", "2 lb 8 oz", "1/2 cup + 2 tbsp", "1 or 2 cloves", "3 cloves (2 if large)", "1 (15 oz can",
                      "2 cups (packed", "1 (2 if small) can"])
    func anAmountThatIsntOneSimpleNumberIsLeftToThePerson(amount: String) {
        let meal = dish("Stew", [(beef, "beef", amount)])
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: meal.id, home: [], doubled: true)], library: [meal])
        #expect(lines[0].quantity == "\(amount) (get double)")
    }

    @Test func aPackageSizeIsntPartOfTheAmount() {
        let meal = dish("Stew", [(beans, "beans", "1 (15 oz) can")])
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: meal.id, home: [], doubled: true)], library: [meal])
        #expect(lines[0].quantity == "2 (15 oz) can (doubled)")
    }

    @Test(arguments: [("2 cups (packed)", "4 cups (packed)"), ("1 (14.5-ounce) can", "2 (14.5-ounce) can"),
                      ("1 (15 oz.) can", "2 (15 oz.) can"), ("1 (400g) tin", "2 (400g) tin")])
    func aBracketWithoutANumberOrARealPackageSizeStillScales(amount: String, doubled: String) {
        #expect(QuantityScaler.scaledIfSimple(amount, by: 2) == doubled)
    }

    @Test func onlyTheDoubledNightsShareOfASharedItemScales() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true),
                                              WeeklyList.Night(mealID: tacos.id, home: [])],
                                     library: [chili, tacos])
        #expect(lines.first { $0.itemID == beef }?.quantity == "3 lb (doubled) + 1 lb")
        #expect(lines.first { $0.itemID == shells }?.quantity == "12", "tacos aren't doubled")
    }

    @Test func aMixedLineSaysWhichPartIsAlreadyDoubled() {
        let soup = dish("Soup", [(beef, "ground beef", "a big can")])
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true),
                                              WeeklyList.Night(mealID: soup.id, home: [], doubled: true)],
                                     library: [chili, soup])
        #expect(lines.first { $0.itemID == beef }?.quantity == "3 lb (doubled) + a big can (get double)")
    }

    @Test func rebuildingTheListNeverScalesTwiceAndUndoingRestoresIt() {
        let doubled = [WeeklyList.Night(mealID: chili.id, home: [], doubled: true)]
        let first = WeeklyList.build(nights: doubled, library: [chili])
        #expect(WeeklyList.build(nights: doubled, library: [chili]) == first, "Update the list twice is one scale")
        let undone = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [])], library: [chili])
        #expect(undone.first { $0.itemID == beef }?.quantity == "1 1/2 lb")
    }

    @Test func aDoubledDishStillGetsItsAllergyNote() {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [nora], doubled: true)],
                                     library: [chili], allergies: allergies)
        #expect(lines.first { $0.itemID == salsa }?.note == "Get dairy-free (Nora)")
    }

    @Test func aFreezerNightBuysOnlyItsSides() {
        let bread = UUID()
        let meal = dish("Lasagna", [(beef, "ground beef", "1 lb")], sides: [.item(itemID: bread, name: "garlic bread")])
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: meal.id, home: [], fromFreezer: true)], library: [meal])
        #expect(lines.map(\.itemID) == [bread])
    }

    @Test func aLeftoversNightBuysNothing() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: nil, home: [])], library: [chili])
        #expect(lines.isEmpty)
    }

    @Test func theLayoutSaysWhichNightsAreDoubledAndWhichAreFromTheFreezer() {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let wednesday = night(3, meal: tacos, stashItemID: UUID())
        let thursday = night(4, meal: tacos)
        let layout = WeekLayout(nights: [monday, tuesday, wednesday, thursday], today: sunday)
        let nights = DoubleIt.listNights(layout, library: [], allergies: [])
        #expect(nights.map(\.doubled) == [true, false, false, false])
        #expect(nights.map(\.fromFreezer) == [false, false, true, false])
    }

    @Test func someoneHomeOnlyForTheLeftoversStillGetsAnAllergyNote() throws {
        let monday = night(1, meal: chili, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id, home: [nora: true, owen: true])
        let nights = DoubleIt.listNights(WeekLayout(nights: [monday, tuesday], today: sunday), library: [], allergies: [])
        #expect(nights[0].home == [nora, owen], "the extra batch is for Tuesday's table too")
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
        let lines = WeeklyList.build(nights: nights, library: [chili], allergies: allergies)
        #expect(lines.first { $0.itemID == salsa }?.note == "Get dairy-free (Nora)")
    }

    @Test func tonightLeavesTheListOnceItsDinnerIsLogged() {
        let tonight = night(0, meal: chili)
        let tomorrow = night(1, meal: tacos)
        let layout = WeekLayout(nights: [tonight, tomorrow], today: sunday)
        #expect(DoubleIt.listNights(layout, library: [], allergies: []).map(\.mealID) == [chili.id, tacos.id])
        #expect(DoubleIt.listNights(layout, logged: [tonight.id], library: [], allergies: []).map(\.mealID) == [tacos.id])
    }

    @Test func aNightWithNoLeftoversNightIsNotDoubled() {
        let layout = WeekLayout(nights: [night(1, meal: chili), night(2, meal: tacos)], today: sunday)
        #expect(DoubleIt.listNights(layout, library: [], allergies: []).allSatisfy { !$0.doubled })
    }

    @Test func nightsOnlyOnTheAwayListDoNotCount() {
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let layout = WeekLayout(nights: [monday, tuesday], today: sunday,
                                away: [AwayDates(from: sunday.adding(days: 1), to: sunday.adding(days: 1))])
        #expect(DoubleIt.listNights(layout, library: [], allergies: []).map(\.mealID) == [nil], "Monday is away, so its dish isn't bought")
    }
}

struct DoubleItChoicesTests {
    private func layout(_ nights: [WeekNight], today: CalendarDay = sunday) -> WeekLayout {
        WeekLayout(nights: nights, today: today)
    }

    @Test func offersLaterNightsThatCanTakeLeftovers() {
        let monday = night(1, meal: chili)
        let open = night(2)
        let planned = night(3, meal: tacos)
        let built = night(4, pick: .leftovers, locked: true)
        let locked = night(5, meal: tacos, locked: true)
        let event = night(6, effort: .event)
        let earlier = night(0)
        let choices = DoubleIt.choices(for: monday, in: layout([earlier, monday, open, planned, built, locked, event]))
        #expect(choices.map(\.id) == [open.id, planned.id, built.id])
    }

    @Test func nobodyHomeAnotherLeftoversNightAFeederAndAFreezerNightAreNotOffered() {
        let monday = night(1, meal: chili)
        let empty = night(2, home: [nora: false, owen: false])
        let feeder = night(3, meal: tacos)
        let fed = night(4, pick: .leftovers, leftoversFrom: feeder.id)
        let freezer = night(5, meal: tacos, stashItemID: UUID())
        #expect(DoubleIt.choices(for: monday, in: layout([monday, empty, feeder, fed, freezer])).isEmpty)
    }

    @Test func awayNightsAreNotOffered() {
        let monday = night(1, meal: chili)
        let tuesday = night(2)
        let away = WeekLayout(nights: [monday, tuesday], today: sunday,
                              away: [AwayDates(from: tuesday.date, to: tuesday.date)])
        #expect(DoubleIt.choices(for: monday, in: away).isEmpty)
    }

    @Test func onlyADishTonightOrLaterThatIsntDoubledOrFromTheFreezerCanBeDoubled() {
        let past = night(0, meal: chili)
        let monday = night(1, meal: chili)
        let fed = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let pick = night(3, pick: .takeout)
        let freezer = night(4, meal: tacos, stashItemID: UUID())
        let plain = night(5, meal: tacos)
        let week = layout([past, monday, fed, pick, freezer, plain], today: sunday.adding(days: 1))
        #expect(!DoubleIt.canDouble(past, in: week), "already happened")
        #expect(!DoubleIt.canDouble(monday, in: week), "already doubled")
        #expect(!DoubleIt.canDouble(fed, in: week), "nothing to cook")
        #expect(!DoubleIt.canDouble(pick, in: week))
        #expect(!DoubleIt.canDouble(freezer, in: week), "already cooked")
        #expect(DoubleIt.canDouble(plain, in: week))
    }

    @Test func aLeftoversNightNamesItsDishOnlyWhenItKnows() {
        let monday = night(1, meal: chili)
        let linked = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let unlinked = night(3, pick: .leftovers)
        let library = [chili, tacos]
        #expect(DoubleIt.leftoversDish(on: linked, nights: [monday, linked, unlinked], library: library)?.id == chili.id)
        #expect(DoubleIt.leftoversDish(on: unlinked, nights: [monday, linked, unlinked], library: library) == nil)
    }

    @Test func aLeftoversNightAfterABigBatchCarriesThatDish() {
        let batch = dish("Pot roast", [], tags: [.leftovers])
        let monday = night(1, meal: batch)
        let tuesday = night(2, pick: .leftovers)
        let friday = night(5, pick: .leftovers)
        let library = [batch]
        #expect(DoubleIt.leftoversDish(on: tuesday, nights: [monday, tuesday, friday], library: library)?.id == batch.id)
        #expect(DoubleIt.leftoversDish(on: friday, nights: [monday, tuesday, friday], library: library) == nil)
    }
}

struct DoubleItWarningTests {
    @Test func changingALinkedNightSaysWhatElseMoves() {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let freezer = night(3, meal: tacos, stashItemID: UUID())
        let plain = night(4, meal: tacos)
        let week = [monday, tuesday, freezer, plain]
        #expect(DoubleIt.changeWarning(for: monday, in: week)?.contains("leftovers night") == true)
        #expect(DoubleIt.changeWarning(for: tuesday, in: week)?.contains("regular amounts") == true)
        #expect(DoubleIt.changeWarning(for: freezer, in: week)?.contains("back in the freezer") == true)
        #expect(DoubleIt.changeWarning(for: plain, in: week) == nil)
    }

    @Test func theDialogSaysWhatTheListWontDo() {
        let note = DoubleIt.listNote(approved: false)
        #expect(note.contains("in stock"))
        #expect(note.contains("another approved week"), "a line another week owns stays as it is")
        #expect(DoubleIt.listNote(approved: true).contains("already bought"))
    }
}

struct DoubleItCardTests {
    private let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]

    @Test func aLeftoversNightStillFlagsItsDishForWhoeversHomeThatNight() {
        let badges = NightBadges.badges(meal: chili, library: [chili], allergies: allergies, home: [nora], alreadyCooked: true)
        #expect(badges.count == 1)
        guard case .allergy(let text) = badges.first else { Issue.record("no allergy flag"); return }
        #expect(text.contains("Nora"))
        #expect(NightBadges.badges(meal: chili, library: [chili], allergies: allergies, home: [owen],
                                   alreadyCooked: true).isEmpty, "Nora's out that night")
    }

    @Test func somethingAlreadyCookedHasNoCookingBadges() {
        var meal = dish("Slow cooker chili", [(salsa, "milk", nil)], tags: [.slowCooker])
        meal.prepSteps = [PrepStep(step: "Thaw the beef", leadHours: 24)]
        var settings = HouseholdSettings()
        settings.missingEquipment = [.slowCooker]
        let start = StartCooking(cookMinutes: 30, isEstimate: false, startMinute: 600, dinnerMinute: 630)
        let cooked = NightBadges.badges(meal: meal, library: [meal], allergies: allergies, home: [nora], settings: settings,
                                        start: start, alreadyCooked: true)
        #expect(cooked.allSatisfy { if case .allergy = $0 { true } else { false } })
        #expect(cooked.count == 1)
    }

    @MainActor
    @Test func theWeekCardDeliversTheFlagAndNoteToALeftoversNight() {
        let monday = night(1, meal: chili, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id, home: [nora: true, owen: true])
        let card = WeekStore.planCard(for: tuesday, nights: [monday, tuesday], members: [], library: [chili],
                                      allergies: allergies, settings: HouseholdSettings(), today: sunday, minuteNow: 0, lookup: .loaded)
        #expect(card.badges.count == 1)
        guard case .allergy(let text) = card.badges.first else { Issue.record("no allergy flag"); return }
        #expect(text.contains("Nora"))
        #expect(card.leftoversNote == "From Monday's Chili")
        let dish = WeekStore.planCard(for: monday, nights: [monday, tuesday], members: [], library: [chili],
                                      allergies: allergies, settings: HouseholdSettings(), today: sunday, minuteNow: 0, lookup: .loaded)
        #expect(dish.badges == [.doubled("Doubled: leftovers Tuesday")], "Nora's out for the dish itself")
    }

    @MainActor
    @Test func theCardCarriesTheLeftoversDishesFlagsAndNote() {
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let card = WeekStore.card(for: tuesday, members: [], badges: { mealID, _ in
            mealID == chili.id ? [.allergy("Contains milk (Nora)")] : []
        }, leftoversDish: chili.id, leftoversNote: "From Monday's Chili")
        #expect(card.slot == .quickPick(.leftovers))
        #expect(card.badges == [.allergy("Contains milk (Nora)")])
        #expect(card.leftoversNote == "From Monday's Chili")
        #expect(DayCardText.accessibilitySummary(card, today: sunday).contains("From Monday's Chili"))
    }

    @Test func wordsOnTheCardNameTheDayAndDish() {
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        #expect(DoubleIt.leftoversNote(from: monday) == "From Monday's Chili")
        #expect(DoubleIt.doubledText(leftoversOn: tuesday, today: sunday) == "Doubled: leftovers Tuesday")
    }
}

// MARK: - The store

private actor Calls {
    var doubles: [DoubleItRequest] = []
    var undos: [UUID] = []
    var loads = 0
    func record(_ request: DoubleItRequest) { doubles.append(request) }
    func record(undo night: UUID) { undos.append(night) }
    func loaded() { loads += 1 }
}

@MainActor
struct DoubleItStoreTests {
    private func week(_ nights: [WeekNight], approved: Bool = false) -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: approved ? .now : nil, nights: nights)
    }

    private func store(_ client: WeekClient) async -> WeekStore {
        let store = WeekStore(householdID: Household.sample.id, client: client, today: { sunday })
        await store.load(settings: HouseholdSettings())
        return store
    }

    @Test func doublingSendsWhatTheDeviceSawAndShowsThePair() async throws {
        let monday = night(1, meal: chili), tuesday = night(2, meal: tacos)
        let saved = week([monday, tuesday])
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in saved }, doubleIt: { await calls.record($0) }))

        #expect(await store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        let sent = try #require(await calls.doubles.first)
        #expect(sent == DoubleItRequest(nightID: monday.id, leftoversNightID: tuesday.id, expectedMeal: chili.id,
                                        expectedLeftoversMeal: tacos.id, expectedLeftoversPick: nil))
        let later = try #require(store.week?.nights[1])
        #expect(later.quickPick == .leftovers)
        #expect(later.mealID == nil)
        #expect(later.locked)
        #expect(later.leftoversFrom == monday.id)
        #expect(store.week?.nights[0].locked == true)
    }

    @Test func undoingReadsTheNightsBackFromTheServer() async throws {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let restored = night(2, meal: tacos)
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in
            await calls.loaded()
            return await calls.undos.isEmpty ? week([monday, tuesday]) : week([monday, restored])
        }, undoDouble: { await calls.record(undo: $0) }))

        #expect(await store.undoDouble(nightID: monday.id))
        #expect(await calls.undos == [monday.id])
        #expect(store.week?.nights[1].mealID == tacos.id, "what the night held before, which only the server knows")
    }

    @Test func undoFromTheLeftoversNightUndoesItsDish() async throws {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let saved = week([monday, tuesday])
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in saved }, undoDouble: { await calls.record(undo: $0) }))
        #expect(await store.undoDouble(nightID: tuesday.id))
        #expect(await calls.undos == [monday.id])
    }

    @Test func aStalePhoneIsToldTheNightChangedNotToCheckItsConnection() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday])
        let store = await store(.fake(week: { _, _ in saved }, doubleIt: { _ in
            throw PostgrestError(code: "FD001", message: "changed")
        }))
        #expect(await !store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(store.errorMessage?.contains("changed") == true)
        #expect(store.errorMessage?.contains("connection") == false)
        #expect(store.week?.nights[1].quickPick == nil, "and the week shows what the server has")
    }

    @Test func aNonPlannerIsToldWhoCanDoIt() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday])
        let store = await store(.fake(week: { _, _ in saved }, doubleIt: { _ in
            throw PostgrestError(code: "42501", message: "refused")
        }))
        #expect(await !store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(store.errorMessage?.contains("planner") == true)
    }

    /// The server's triggers move the other night, so a swap on either end has to read the week back.
    @Test(arguments: [0, 1])
    func swappingEitherNightOfThePairReadsTheWeekBack(index: Int) async {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let saved = week([monday, tuesday])
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in
            await calls.loaded()
            return saved
        }))
        let before = await calls.loads
        #expect(await store.swap(nightID: saved.nights[index].id, to: .quickPick(.takeout)))
        #expect(await calls.loads == before + 1)
    }

    @Test func swappingAnUnrelatedNightDoesNotReload() async {
        let plain = night(1, meal: chili)
        let saved = week([plain])
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in
            await calls.loaded()
            return saved
        }))
        let before = await calls.loads
        #expect(await store.swap(nightID: plain.id, to: .quickPick(.takeout)))
        #expect(await calls.loads == before)
    }

    @Test func aShuffleThatChangesTheDoubledNightReadsTheWeekBack() async {
        let other = LibraryMeal.fixture(name: "Soup")
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let saved = week([monday, tuesday])
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in
            await calls.loaded()
            return saved
        }))
        let before = await calls.loads
        await store.shuffle(nightID: monday.id) {
            PlanningContext(meals: [chili, other], history: [], settings: HouseholdSettings(), members: [])
        }
        #expect(await calls.loads == before + 1)
    }

    @Test func onAnApprovedWeekDoublingSaysTheListNeedsUpdatingUntilItsWritten() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday], approved: true)
        let store = await store(.fake(week: { _, _ in saved }))
        #expect(!store.listNeedsUpdating)
        #expect(await store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(store.listNeedsUpdating)
        #expect(await store.approve([]))
        #expect(!store.listNeedsUpdating, "updating the list settles it")
    }

    @Test func undoingOnAnApprovedWeekAndAnotherPhonesChangeBothReadFromThePlan() async {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        var stale = week([monday, night(2)], approved: true)
        stale.listStale = true
        let behind = stale
        let settled = week([monday, tuesday], approved: true)
        let calls = Calls()
        let store = await store(.fake(week: { _, _ in await calls.undos.isEmpty ? settled : behind },
                                      undoDouble: { await calls.record(undo: $0) }))
        #expect(!store.listNeedsUpdating)
        #expect(await store.undoDouble(nightID: monday.id))
        #expect(store.listNeedsUpdating, "the server's flag, so a cold start or the other phone sees it too")
    }

    @Test func aFreezerPickOnAPastNightDoesntSayTheListIsBehind() async {
        let past = night(-1)
        let saved = week([past], approved: true)
        let store = await store(.fake(week: { _, _ in saved }))
        let frozen = FreezerItem(id: UUID(), mealID: chili.id, mealName: "Chili", madeOn: sunday.adding(days: -30), state: .in)
        #expect(await store.swap(nightID: past.id, to: .freezer(frozen, reason: "x")))
        #expect(!store.listNeedsUpdating)
    }

    @Test func aFailedReadStopsTheListBeingWritten() async {
        let monday = night(1, meal: chili)
        let saved = week([monday], approved: true)
        let loaded = Mutex(false)
        let approved = Mutex(0)
        let store = await store(.fake(
            week: { _, _ in
                guard loaded.withLock({ $0 }) else { return saved }
                throw URLError(.notConnectedToInternet)
            },
            approve: { _, _ in approved.withLock { $0 += 1 } }
        ))
        loaded.withLock { $0 = true }
        #expect(await !store.approveLatest { _ in [] })
        #expect(approved.withLock { $0 } == 0, "an old copy of the week isn't what the list is written from")
        #expect(store.errorMessage?.contains("wasn't updated") == true)
    }

    @Test func aReadAbandonedForBusyTapsDoesntCountAsARead() async {
        let monday = night(1, meal: chili)
        let saved = week([monday], approved: true)
        let current = Mutex<WeekStore?>(nil)
        let approved = Mutex(0)
        let store = await store(.fake(
            week: { _, _ in
                if let busy = current.withLock({ $0 }) { await busy.toggleAttendance(nightID: monday.id, memberID: nora) }
                return saved
            },
            approve: { _, _ in approved.withLock { $0 += 1 } }
        ))
        current.withLock { $0 = store }
        #expect(await !store.refresh())
        #expect(await !store.approveLatest { _ in [] })
        #expect(approved.withLock { $0 } == 0)
    }

    @Test func theListIsBuiltFromTheWeekJustRead() async throws {
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let before = week([monday, night(2)], approved: true)
        let after = Week(planID: before.planID, start: sunday, approvedAt: before.approvedAt, nights: [monday, tuesday])
        let loaded = Mutex(false)
        let store = await store(.fake(week: { _, _ in loaded.withLock { $0 } ? after : before }))
        loaded.withLock { $0 = true }
        let seen = Mutex(false)
        #expect(await store.approveLatest { layout in
            seen.withLock { $0 = DoubleIt.listNights(layout, library: [], allergies: []).contains(where: \.doubled) }
            return []
        })
        #expect(seen.withLock { $0 }, "another planner's doubling counts")
    }

    @Test func aTapStartedWhileWaitingIsAlsoWaitedForBeforeReading() async throws {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let wednesday = night(3)
        let saved = week([monday, tuesday, wednesday])
        let reads = Mutex(0)
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (firstGate, releaseFirst) = AsyncStream.makeStream(of: Void.self)
        let (secondGate, releaseSecond) = AsyncStream.makeStream(of: Void.self)
        let (swapWrote, swapWroteSignal) = AsyncStream.makeStream(of: Void.self)
        let store = await store(.fake(
            week: { _, _ in
                reads.withLock { $0 += 1 }
                return saved
            },
            setExpected: { nightID, _, _ in
                parkedSignal.yield()
                for await _ in nightID == monday.id ? firstGate : secondGate {}
            },
            setNight: { _, _ in swapWroteSignal.yield() }
        ))
        var signals = parked.makeAsyncIterator()
        let first = Task { await store.toggleAttendance(nightID: monday.id, memberID: nora) }
        _ = await signals.next()
        let swap = Task { await store.swap(nightID: tuesday.id, to: .quickPick(.takeout)) }
        for await _ in swapWrote { break }
        for _ in 0..<50 { await Task.yield() }
        let second = Task { await store.toggleAttendance(nightID: wednesday.id, memberID: nora) }
        _ = await signals.next()
        let before = reads.withLock { $0 }
        releaseFirst.finish()
        await first.value
        for _ in 0..<50 { await Task.yield() }
        #expect(reads.withLock { $0 } == before, "no read alongside the second tap")
        releaseSecond.finish()
        await second.value
        #expect(await swap.value)
        #expect(reads.withLock { $0 } == before + 1)
    }

    @Test func aReadStartedBeforeABuildSavedIsntShownOverIt() async throws {
        let open = night(1)
        let before = week([open])
        let drafted = Mutex(false)
        let reads = Mutex(0)
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let meal = LibraryMeal.fixture(name: "Soup")
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in
                let read = reads.withLock { $0 += 1; return $0 }
                if read == 2 {
                    parkedSignal.yield()
                    for await _ in gate {}
                    return before
                }
                guard drafted.withLock({ $0 }) else { return before }
                var after = before
                after.nights[0].mealID = meal.id
                after.nights[0].mealName = "Soup"
                return after
            },
            setNights: { _, _ in drafted.withLock { $0 = true } }
        ), today: { sunday }, seed: { 3 })
        await store.load(settings: HouseholdSettings())
        let slow = Task { await store.refresh() }
        for await _ in parked { break }
        await store.fillRemaining { PlanningContext(meals: [meal], history: [], settings: HouseholdSettings(), members: []) }
        release.finish()
        #expect(await slow.value)
        #expect(store.week?.nights[0].mealID == meal.id, "the old read isn't put over the saved draft")
    }

    /// A reload after a linked write must not overwrite a tap still on its way to the server.
    @Test func aReloadAfterALinkedWriteWaitsForAnAttendanceTapInFlight() async throws {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let saved = week([monday, tuesday])
        let tapped = Mutex(false)
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let (swapWrote, swapWroteSignal) = AsyncStream.makeStream(of: Void.self)
        let store = await store(.fake(
            week: { _, _ in
                var current = saved
                if tapped.withLock({ $0 }) { current.nights[0].attendance[nora] = false }
                return current
            },
            setExpected: { _, _, _ in
                parkedSignal.yield()
                for await _ in gate {}
                tapped.withLock { $0 = true }
            },
            setNight: { _, _ in swapWroteSignal.yield() }
        ))
        let tap = Task { await store.toggleAttendance(nightID: monday.id, memberID: nora) }
        for await _ in parked { break }
        let swap = Task { await store.swap(nightID: tuesday.id, to: .quickPick(.takeout)) }
        for await _ in swapWrote { break }
        for _ in 0..<50 { await Task.yield() }
        #expect(store.week?.nights[0].attendance[nora] == false, "the tap still shows")
        release.finish()
        await tap.value
        #expect(await swap.value)
        #expect(store.week?.nights[0].attendance[nora] == false, "and the read back includes it")
    }

    @Test func beforeApprovalThereIsNoListToUpdate() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday])
        let store = await store(.fake(week: { _, _ in saved }))
        #expect(await store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(!store.listNeedsUpdating)
    }
}

/// Every path that plans a night leaves a real doubled pair alone: both nights are saved locked and linked.
@MainActor
struct DoubleItPlanningTests {
    private let meals = (0..<6).map { LibraryMeal.fixture(name: "Dish \($0)") } + [chili]

    private func pair() -> (Week, monday: WeekNight, tuesday: WeekNight) {
        let monday = night(1, meal: chili, locked: true)
        let tuesday = night(2, pick: .leftovers, locked: true, leftoversFrom: monday.id)
        let others = [0, 3, 4].map { night($0) }
        return (Week(planID: UUID(), start: sunday, nights: [others[0], monday, tuesday, others[1], others[2]]), monday, tuesday)
    }

    private func context() -> PlanningContext {
        PlanningContext(meals: meals, history: [], settings: HouseholdSettings(), members: [])
    }

    @Test func rebuildAndFillNeverWriteThePair() async throws {
        let (saved, monday, tuesday) = pair()
        let written = Mutex<[[UUID]]>([])
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in saved },
            setNights: { _, updates in written.withLock { $0.append(updates.map(\.nightID)) } }
        ), today: { sunday }, seed: { 3 })
        await store.load(settings: HouseholdSettings())
        await store.buildWeek { context() }
        await store.fillRemaining { context() }
        let writes = written.withLock { $0 }
        #expect(!writes.isEmpty)
        #expect(writes.allSatisfy { !$0.contains(monday.id) && !$0.contains(tuesday.id) })
        #expect(store.week?.nights[2].leftoversFrom == monday.id)
        #expect(store.week?.nights[1].mealID == chili.id)
    }

    @Test func shuffleNeverWritesThePair() async throws {
        let (saved, monday, tuesday) = pair()
        let written = Mutex(0)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in saved },
            setNights: { _, _ in written.withLock { $0 += 1 } }
        ), today: { sunday }, seed: { 3 })
        await store.load(settings: HouseholdSettings())
        await store.shuffle(nightID: monday.id) { context() }
        await store.shuffle(nightID: tuesday.id) { context() }
        #expect(written.withLock { $0 } == 0)
    }

    /// Swapping the leftovers night away, then asking what the list buys.
    @Test func afterTheLeftoversNightLeavesTheDishIsNoLongerDoubled() async throws {
        let (saved, monday, tuesday) = pair()
        let swapped = Mutex(false)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in
                guard swapped.withLock({ $0 }) else { return saved }
                var after = saved
                after.nights[2].quickPick = .takeout
                after.nights[2].leftoversFrom = nil
                return after
            },
            setNight: { _, _ in swapped.withLock { $0 = true } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(store.layout.map { DoubleIt.listNights($0, library: [], allergies: []) }?.contains { $0.doubled } == true)
        #expect(await store.swap(nightID: tuesday.id, to: .quickPick(.takeout)))
        #expect(store.layout.map { DoubleIt.listNights($0, library: [], allergies: []) }?.contains { $0.doubled } == false)
        #expect(store.week?.nights[1].id == monday.id)
    }
}
