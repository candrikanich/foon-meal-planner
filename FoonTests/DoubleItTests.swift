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
        let meat = lines.first { $0.itemID == beef }
        #expect(meat?.quantity == "3 lb")
        #expect(meat?.note == "Doubled for Chili")
    }

    @Test func anAmountThatWontScaleStaysAsWrittenAndTheNoteSaysToGetDouble() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true)], library: [chili])
        let can = lines.first { $0.itemID == beans }
        #expect(can?.quantity == "a big can")
        #expect(can?.note == "Get double for Chili")
        let noAmount = lines.first { $0.itemID == salsa }
        #expect(noAmount?.quantity == nil)
        #expect(noAmount?.note == "Get double for Chili")
    }

    @Test func onlyTheDoubledNightsShareOfASharedItemScales() {
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [], doubled: true),
                                              WeeklyList.Night(mealID: tacos.id, home: [])],
                                     library: [chili, tacos])
        #expect(lines.first { $0.itemID == beef }?.quantity == "3 lb + 1 lb")
        #expect(lines.first { $0.itemID == shells }?.quantity == "12", "tacos aren't doubled")
        #expect(lines.first { $0.itemID == shells }?.note == nil)
    }

    @Test func rebuildingTheListNeverScalesTwiceAndUndoingRestoresIt() {
        let doubled = [WeeklyList.Night(mealID: chili.id, home: [], doubled: true)]
        let first = WeeklyList.build(nights: doubled, library: [chili])
        #expect(WeeklyList.build(nights: doubled, library: [chili]) == first, "Update the list twice is one scale")
        let undone = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [])], library: [chili])
        #expect(undone.first { $0.itemID == beef }?.quantity == "1 1/2 lb")
        #expect(undone.allSatisfy { $0.note == nil })
    }

    @Test func allergyNotesAlwaysFitAndComeBeforeTheDoubledNote() {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: chili.id, home: [nora], doubled: true)],
                                     library: [chili], allergies: allergies)
        #expect(lines.first { $0.itemID == salsa }?.note == "Get dairy-free (Nora); Get double for Chili")

        let many = (0..<14).map { "ingredient number \($0)" }
        let flagged = MemberAllergies(memberID: nora, firstName: "Nora", customTexts: many)
        var crowded = LibraryMeal.fixture(name: "Crowded")
        crowded.ingredients = [MealIngredient(itemID: beef, name: many.joined(separator: " "), quantityText: "1 lb", position: 1)]
        let line = WeeklyList.build(nights: [WeeklyList.Night(mealID: crowded.id, home: [nora], doubled: true)],
                                    library: [crowded], allergies: [flagged])[0]
        #expect((line.note?.unicodeScalars.count ?? 0) <= 140, "the database's limit")
        #expect(line.note?.contains("Check") == true, "and the allergy is what stays")
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
        let nights = DoubleIt.listNights(layout)
        #expect(nights.map(\.doubled) == [true, false, false, false])
        #expect(nights.map(\.fromFreezer) == [false, false, true, false])
    }

    @Test func aNightWhoseLeftoversNightLeftIsNoLongerDoubled() {
        let layout = WeekLayout(nights: [night(1, meal: chili), night(2, meal: tacos)], today: sunday)
        #expect(DoubleIt.listNights(layout).allSatisfy { !$0.doubled })
    }

    @Test func nightsOnlyOnTheAwayListDoNotCount() {
        let monday = night(1, meal: chili)
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        let layout = WeekLayout(nights: [monday, tuesday], today: sunday,
                                away: [AwayDates(from: sunday.adding(days: 1), to: sunday.adding(days: 1))])
        #expect(DoubleIt.listNights(layout).map(\.mealID) == [nil], "Monday is away, so its dish isn't bought")
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

    @Test func onAnApprovedWeekDoublingAndUndoingSayTheListNeedsUpdating() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday], approved: true)
        let store = await store(.fake(week: { _, _ in saved }))
        #expect(!store.listNeedsUpdating)
        #expect(await store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(store.listNeedsUpdating)
        #expect(await store.approve([]))
        #expect(!store.listNeedsUpdating, "updating the list settles it")
    }

    @Test func beforeApprovalThereIsNoListToUpdate() async {
        let monday = night(1, meal: chili), tuesday = night(2)
        let saved = week([monday, tuesday])
        let store = await store(.fake(week: { _, _ in saved }))
        #expect(await store.doubleIt(nightID: monday.id, leftoversNightID: tuesday.id))
        #expect(!store.listNeedsUpdating)
    }
}

/// Every path that plans a night leaves a doubled pair alone, because both are saved locked.
struct DoubleItPlanningTests {
    private func inputs() -> (PlanningInputs, monday: PlanningNight, tuesday: PlanningNight) {
        let monday = PlanningNight(id: UUID(), date: sunday.adding(days: 1), attendance: [nora: true], locked: true,
                                   mealID: chili.id)
        let tuesday = PlanningNight(id: UUID(), date: sunday.adding(days: 2), attendance: [nora: true], locked: true,
                                    quickPick: .leftovers)
        let others = [0, 3, 4].map { PlanningNight(id: UUID(), date: sunday.adding(days: $0), attendance: [nora: true]) }
        let meals = (0..<6).map { LibraryMeal.fixture(name: "Dish \($0)") } + [chili]
        return (PlanningInputs(nights: [monday, tuesday] + others, meals: meals, today: sunday), monday, tuesday)
    }

    @Test func buildAndFillKeepThePairAndCountTheLeftovers() {
        let (planning, monday, tuesday) = inputs()
        let draft = BuildMyWeek.draft(planning, seed: 3)
        #expect(draft.first { $0.nightID == monday.id }?.pick == .meal(chili.id))
        #expect(draft.first { $0.nightID == tuesday.id }?.pick == .quickPick(.leftovers))
        #expect(draft.filter { $0.pick == .quickPick(.leftovers) }.count == 1, "it's the week's leftovers night")
    }

    @Test func shuffleLeavesThemAlone() {
        let (planning, monday, tuesday) = inputs()
        #expect(BuildMyWeek.shuffle(night: monday.id, inputs: planning, seed: 1) == nil)
        #expect(BuildMyWeek.shuffle(night: tuesday.id, inputs: planning, seed: 1) == nil)
    }
}
