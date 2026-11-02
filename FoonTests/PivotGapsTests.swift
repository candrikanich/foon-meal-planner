import Foundation
import Testing
@testable import Foon

struct PivotGapsTests {
    private let milk = UUID(), rice = UUID(), beans = UUID(), nora = UUID(), plan = UUID()
    private let dish: LibraryMeal

    init() {
        var meal = LibraryMeal.fixture(name: "Rice and beans")
        meal.ingredients = [MealIngredient(itemID: rice, name: "rice", quantityText: "1 cup", position: 1),
                            MealIngredient(itemID: beans, name: "beans", quantityText: nil, position: 2),
                            MealIngredient(itemID: milk, name: "milk", quantityText: nil, position: 3)]
        dish = meal
    }

    private func gaps(stock: [UUID: StockState] = [:], allergies: [MemberAllergies] = [], home: Set<UUID> = [],
                      open: [PivotGaps.OpenLine] = [], fromFreezer: Bool = false, tonight: Bool = false) -> [WeeklyList.Line] {
        fullGaps(stock: stock, allergies: allergies, home: home, open: open, fromFreezer: fromFreezer, tonight: tonight).map(\.line)
    }

    private func fullGaps(stock: [UUID: StockState] = [:], allergies: [MemberAllergies] = [], home: Set<UUID> = [],
                          open: [PivotGaps.OpenLine] = [], fromFreezer: Bool = false, tonight: Bool = false) -> [PivotGaps.Gap] {
        PivotGaps.gaps(for: WeeklyList.Night(mealID: dish.id, home: home, fromFreezer: fromFreezer), library: [dish], stock: stock,
                       allergies: allergies, open: open, tonight: tonight)
    }

    private var noraNoMilk: [MemberAllergies] {
        [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
    }

    @Test func whatsInStockIsntAGap() {
        #expect(gaps(stock: [rice: .in]).map(\.itemID) == [beans, milk])
    }

    @Test func aLowStapleIsStillAGap() {
        #expect(gaps(stock: [rice: .low]).contains { $0.itemID == rice })
    }

    @Test func whatsAlreadyListedIsntAddedAgain() {
        #expect(gaps(open: [PivotGaps.OpenLine(itemID: rice, note: nil)]).map(\.itemID) == [beans, milk])
    }

    @Test func aGapCarriesItsAllergyNote() {
        #expect(gaps(allergies: noraNoMilk, home: [nora]).first { $0.itemID == milk }?.note?.contains("Nora") == true)
    }

    @Test func anAllergyNoteTheListedLineLacksStillGoesOn() {
        let listed = gaps(allergies: noraNoMilk, home: [nora], open: [PivotGaps.OpenLine(itemID: milk, note: nil)])
        #expect(listed.contains { $0.itemID == milk })
    }

    @Test func theSameAllergyNoteDoesntGoOnTwice() throws {
        let note = try #require(gaps(allergies: noraNoMilk, home: [nora]).first { $0.itemID == milk }?.note)
        let listed = gaps(allergies: noraNoMilk, home: [nora], open: [PivotGaps.OpenLine(itemID: milk, note: note)])
        #expect(!listed.contains { $0.itemID == milk })
    }

    @Test func aNoteInsideAMergedLineCounts() throws {
        let note = try #require(gaps(allergies: noraNoMilk, home: [nora]).first { $0.itemID == milk }?.note)
        let listed = gaps(allergies: noraNoMilk, home: [nora],
                          open: [PivotGaps.OpenLine(itemID: milk, note: "\(note); Couldn't find it last trip")])
        #expect(!listed.contains { $0.itemID == milk })
    }

    @Test func aGapCarriesItsAmount() {
        #expect(gaps().first { $0.itemID == rice }?.quantity == "1 cup")
    }

    @Test func tonightsDishMarksAListedItemForTonight() {
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil), PivotGaps.OpenLine(itemID: beans, note: nil, isTonight: true)]
        let found = fullGaps(open: open, tonight: true)
        #expect(found.map(\.line.itemID) == [rice, milk], "beans are already for tonight")
        #expect(found.allSatisfy { $0.isNews })
    }

    @Test func aNoteJoiningAListedLineIsntNews() {
        let found = fullGaps(allergies: noraNoMilk, home: [nora], open: [PivotGaps.OpenLine(itemID: milk, note: "Couldn't find it last trip")])
        #expect(found.first { $0.line.itemID == milk }?.isNews == false)
        #expect(found.first { $0.line.itemID == rice }?.isNews == true)
    }

    @Test func aFreezerDinnerOnlyNeedsItsSides() {
        #expect(gaps(fromFreezer: true).isEmpty)
    }

    @Test func updateTheListLeavesOffWhatAPivotAdded() {
        let night = WeeklyList.Night(mealID: dish.id, home: [nora])
        let weekly = WeeklyList.build(nights: [night], library: [dish], allergies: noraNoMilk)
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil, quantity: "1 cup", isPivot: true, planID: plan),
                    PivotGaps.OpenLine(itemID: milk, note: nil, isPivot: true, planID: plan),
                    PivotGaps.OpenLine(itemID: beans, note: nil)]
        #expect(PivotGaps.weekly(weekly, open: open, planID: plan).map(\.itemID) == [beans, milk], "milk has a note to carry; beans were only typed in")
    }

    @Test func updateTheListKeepsAWeeklyLineThatSaysMore() {
        let doubled = WeeklyList.build(nights: [WeeklyList.Night(mealID: dish.id, home: [], doubled: true)], library: [dish])
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil, quantity: "1 cup", isPivot: true, planID: plan)]
        #expect(PivotGaps.weekly(doubled, open: open, planID: plan).contains { $0.itemID == rice }, "the shopper needs the doubled amount")
    }

    @Test func updateTheListDropsALinePivotedWithTheSameAllergyNote() throws {
        let weekly = WeeklyList.build(nights: [WeeklyList.Night(mealID: dish.id, home: [nora])], library: [dish], allergies: noraNoMilk)
        let line = try #require(weekly.first { $0.itemID == milk })
        let open = [PivotGaps.OpenLine(itemID: milk, note: line.note, quantity: line.quantity, isPivot: true, planID: plan)]
        #expect(!PivotGaps.weekly(weekly, open: open, planID: plan).contains { $0.itemID == milk })
    }

    private func night(_ date: CalendarDay, mealID: UUID? = nil, quickPick: QuickPick? = nil, attendance: [UUID: Bool] = [:]) -> WeekNight {
        WeekNight(id: UUID(), date: date, effort: .normal, dinnerTime: nil, mealID: mealID, mealName: nil, quickPick: quickPick,
                  locked: false, attendance: attendance)
    }

    private func outcome(_ target: WeekNight, nights: [WeekNight], today: CalendarDay, logged: Set<UUID> = [], canTrustStock: Bool = true,
                         canTrustLibrary: Bool = true, library: [LibraryMeal]? = nil, allergies: [MemberAllergies] = []) -> PivotGaps.Outcome {
        PivotGaps.outcome(night: target, in: WeekLayout(nights: nights, today: today), logged: logged, canTrustStock: canTrustStock,
                          canTrustLibrary: canTrustLibrary, library: library ?? [dish], stock: [:], allergies: allergies, open: [], today: today)
    }

    private let monday = CalendarDay(year: 2026, month: 11, day: 2)

    @Test func aLoggedDinnerNeedsNothing() {
        let tonight = night(monday, mealID: dish.id)
        #expect(outcome(tonight, nights: [tonight], today: monday, logged: [tonight.id]) == .nothing)
    }

    @Test func whatCantBeReadIsSaidRatherThanLookingLikeNothingMissing() {
        let tonight = night(monday, mealID: dish.id)
        #expect(outcome(tonight, nights: [tonight], today: monday, canTrustStock: false) == .couldntCheck)
        #expect(outcome(tonight, nights: [tonight], today: monday, canTrustLibrary: false) == .couldntCheck)
        #expect(outcome(tonight, nights: [tonight], today: monday, library: []) == .couldntCheck)
    }

    @Test func aDishWithASideNobodyCanReadCouldntBeChecked() {
        var meal = dish
        meal.sides = [.meal(UUID())]
        let tonight = night(monday, mealID: meal.id)
        #expect(outcome(tonight, nights: [tonight], today: monday, library: [meal]) == .couldntCheck)
    }

    @Test func whoeverEatsTheLeftoversCountsForTheNote() throws {
        var bigBatch = dish
        bigBatch.tags = [.leftovers]
        let tonight = night(monday, mealID: bigBatch.id, attendance: [nora: false])
        let tomorrow = night(monday.adding(days: 1), quickPick: .leftovers, attendance: [nora: true])
        guard case .add(let found, _) = outcome(tonight, nights: [tonight, tomorrow], today: monday, library: [bigBatch], allergies: noraNoMilk) else {
            Issue.record("expected gaps")
            return
        }
        #expect(found.first { $0.line.itemID == milk }?.line.note?.contains("Nora") == true)
    }

    @Test func aPivotLineSaysNothingAboutAnotherWeek() {
        let weekly = WeeklyList.build(nights: [WeeklyList.Night(mealID: dish.id, home: [])], library: [dish])
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil, quantity: "1 cup", isPivot: true, planID: plan)]
        #expect(PivotGaps.weekly(weekly, open: open, planID: UUID()).contains { $0.itemID == rice })
    }

    @Test func anAmountThatDiffersIsToldToTheShopper() throws {
        let night = WeeklyList.Night(mealID: dish.id, home: [])
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil, quantity: "3 cups"), PivotGaps.OpenLine(itemID: beans, note: nil)]
        let check = PivotGaps.amountsToCheck(for: night, library: [dish], stock: [:], open: open)
        #expect(check.map(\.itemID) == [rice], "beans have no amount to compare; milk isn't listed")
        let text = try #require(PivotGaps.summary(gaps: [], check: check, tonight: false))
        #expect(text.contains("rice (1 cup)"))
    }

    @Test func theSameAmountNeedsNoCheck() {
        let night = WeeklyList.Night(mealID: dish.id, home: [])
        let open = [PivotGaps.OpenLine(itemID: rice, note: nil, quantity: "1 cup")]
        #expect(PivotGaps.amountsToCheck(for: night, library: [dish], stock: [:], open: open).isEmpty)
    }

    @Test func aNoteJoiningALineIsSaid() throws {
        let found = fullGaps(allergies: noraNoMilk, home: [nora], open: [PivotGaps.OpenLine(itemID: milk, note: nil),
                                                                          PivotGaps.OpenLine(itemID: rice, note: nil),
                                                                          PivotGaps.OpenLine(itemID: beans, note: nil)])
        #expect(PivotGaps.summary(gaps: found, check: [], tonight: false) == "Added an allergy note to milk.")
        #expect(PivotGaps.summary(gaps: [], check: [], tonight: false) == nil)
    }

    @Test func theMessageSaysWhereItWent() {
        #expect(PivotGaps.message(names: [], tonight: true) == nil)
        #expect(PivotGaps.message(names: ["milk"], tonight: true) == "Added milk to the list for tonight.")
        #expect(PivotGaps.message(names: ["milk"], tonight: false) == "Added milk to the quick list.")
    }
}

struct ListNotesTests {
    @Test func noteMergesKeepBothNewestFirst() {
        #expect(ListNotes.merged(existing: "Couldn't find it", incoming: "Get dairy-free (Nora)") == "Get dairy-free (Nora); Couldn't find it")
    }

    @Test func aRepeatOrNothingLeavesTheLine() {
        #expect(ListNotes.merged(existing: "a; b", incoming: "b") == "a; b")
        #expect(ListNotes.merged(existing: "a", incoming: nil) == "a")
        #expect(ListNotes.merged(existing: "a", incoming: "  ") == "a")
        #expect(ListNotes.merged(existing: nil, incoming: "b") == "b")
    }

    @Test func pastTheLimitTheOldestIsCutVisibly() throws {
        let merged = try #require(ListNotes.merged(existing: String(repeating: "a", count: 400), incoming: "Get dairy-free (Nora)"))
        #expect(merged.unicodeScalars.count == ListNotes.limit)
        #expect(merged.hasPrefix("Get dairy-free (Nora); "))
        #expect(merged.hasSuffix("…"))
    }

    @Test func aChangeQueuedByAnOlderBuildStillDecodes() throws {
        let household = UUID(), item = UUID(), line = UUID()
        let change = OfflineChange.addToList(householdID: household, itemID: item, list: .quick, urgency: .whenever, source: .manual,
                                             note: nil, lineID: line)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: [String: Any]])
        json["addToList"]?["quantity"] = nil
        let decoded = try JSONDecoder().decode(OfflineChange.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == change)
    }

    @Test func couldntFindItKeepsTheAllergyNoteAndAmount() throws {
        let entry = ListEntry(lineID: UUID(), itemID: UUID(), name: "Milk", list: .weekly, urgency: .whenever, quantity: "1 cup",
                              lineNote: "Get dairy-free (Nora)", itemNote: nil, category: .other, checkedAt: nil, keepOnHand: false)
        guard case .addToList(_, _, _, _, _, let note, _, let quantity, _) = try #require(ListBoard.couldntFind(entry, householdID: UUID(), newLineID: UUID()).first) else {
            Issue.record("expected an add")
            return
        }
        #expect(note?.contains("Get dairy-free (Nora)") == true)
        #expect(quantity == "1 cup")
    }

    @Test func aStapleKeepsTheNameItWasTypedWith() {
        #expect(KeepOnHandView.names(in: "7 Up, 12 grain bread\n  milk ,") == ["7 Up", "12 grain bread", "milk"])
    }
}

@MainActor
struct PivotSwapTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)
    private let dish = WeekStore.SwapChoice.meal(id: UUID(), name: "Tacos")

    private func store(approved: Bool, today: CalendarDay) async -> (WeekStore, Week) {
        let week = Week(planID: UUID(), start: sunday, approvedAt: approved ? Date.now : nil, nights: (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil, mealID: nil, mealName: nil,
                      quickPick: nil, locked: false, attendance: [:])
        })
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in week }), today: { today })
        await store.load(settings: HouseholdSettings())
        return (store, week)
    }

    @Test func aDishOnANightStillToComeInAnApprovedWeekCounts() async {
        let (store, week) = await store(approved: true, today: sunday)
        #expect(await store.swap(nightID: week.nights[2].id, to: dish))
        #expect(store.swappedDish?.nightID == week.nights[2].id)
    }

    @Test func aDraftHasNoListYet() async {
        let (store, week) = await store(approved: false, today: sunday)
        #expect(await store.swap(nightID: week.nights[2].id, to: dish))
        #expect(store.swappedDish == nil)
    }

    @Test func aNightGoneByNeedsNothing() async {
        let (store, week) = await store(approved: true, today: sunday.adding(days: 3))
        #expect(await store.swap(nightID: week.nights[1].id, to: dish))
        #expect(store.swappedDish == nil)
    }

    @Test func aQuickPickNeedsNothing() async {
        let (store, week) = await store(approved: true, today: sunday)
        #expect(await store.swap(nightID: week.nights[2].id, to: .quickPick(.takeout)))
        #expect(store.swappedDish == nil)
    }

    @Test func theNoteGoesWithTheNextSwap() async {
        let (store, week) = await store(approved: true, today: sunday)
        store.notePivot("Added milk to the quick list.")
        #expect(await store.swap(nightID: week.nights[2].id, to: .quickPick(.takeout)))
        #expect(store.pivotNote == nil)
    }
}
