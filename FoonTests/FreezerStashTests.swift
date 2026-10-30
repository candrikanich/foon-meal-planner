import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let nora = UUID(), owen = UUID()

private func item(_ meal: LibraryMeal, daysAgo: Int = 30, state: FreezerItem.State = .in,
                  plannedOn: CalendarDay? = nil) -> FreezerItem {
    FreezerItem(id: UUID(), mealID: meal.id, mealName: meal.name, madeOn: sunday.adding(days: -daysAgo), state: state,
                plannedOn: plannedOn)
}

private func night(_ offset: Int = 2, meal: LibraryMeal? = nil, home: [UUID: Bool] = [nora: true, owen: false]) -> WeekNight {
    WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil, mealID: meal?.id,
              mealName: meal?.name, quickPick: nil, locked: false, attendance: home)
}

struct FreezerOffersTests {
    private let chili = LibraryMeal.fixture(name: "Chili", ingredients: ["milk"])
    private let soup = LibraryMeal.fixture(name: "Soup")

    private func offers(_ items: [FreezerItem], on target: WeekNight? = nil, others: [WeekNight] = [],
                        notForMe: [UUID: [UUID: Int]] = [:], snoozed: Set<UUID> = [], library: [LibraryMeal]? = nil,
                        allergies: [MemberAllergies] = [], today: CalendarDay = sunday) -> [FreezerStash.Offer] {
        let target = target ?? night()
        return FreezerStash.offers(items, on: target, week: [target] + others, library: library ?? [chili, soup],
                                   notForMe: notForMe, snoozed: snoozed, allergies: allergies, today: today)
    }

    @Test func oldestFirstSoNothingGetsForgotten() {
        let newer = item(soup, daysAgo: 3), older = item(chili, daysAgo: 90)
        #expect(offers([newer, older]).map(\.item.id) == [older.id, newer.id])
    }

    @Test func usedUpAndArchivedItemsArentOffered() {
        #expect(offers([item(chili, state: .used), item(soup, state: .archived)]).isEmpty)
    }

    @Test func anItemMadeAfterTheNightIsntOffered() {
        let future = item(chili, daysAgo: -5)
        #expect(offers([future], on: night(2)).isEmpty)
        #expect(offers([future], on: night(5)).map(\.item.id) == [future.id], "the night it's made is fine")
    }

    @Test func aRetiredOrArchivedDishIsntOffered() {
        let retired = LibraryMeal.fixture(name: "Liver", status: .retired)
        let archived = LibraryMeal.fixture(name: "Old", status: .archived)
        #expect(offers([item(retired), item(archived)], library: [retired, archived]).isEmpty)
    }

    @Test func aDishMissingFromTheLibraryIsntOffered() {
        #expect(offers([item(chili)], library: [soup]).isEmpty, "no ingredients to read, so no allergy flags to trust")
    }

    @Test func aDishSomeoneHomeDislikesIsSkippedOnlyWhileTheyreHome() {
        let frozen = item(chili)
        let dislike = [chili.id: [nora: 1]]
        #expect(offers([frozen], on: night(home: [nora: true, owen: true]), notForMe: dislike).isEmpty)
        #expect(offers([frozen], on: night(home: [nora: false, owen: true]), notForMe: dislike).count == 1)
    }

    @Test func aSnoozedDishIsntOffered() {
        #expect(offers([item(chili)], snoozed: [chili.id]).isEmpty)
    }

    @Test func aDishAlreadyInTheWeekIsntOffered() {
        #expect(offers([item(chili)], others: [night(4, meal: chili)]).isEmpty)
        #expect(offers([item(chili)], on: night(2, meal: chili)).isEmpty, "the night's own dish included")
    }

    @Test func anAllergyNightStillOffersItWithTheFlagForWhoeversHome() throws {
        let allergies = [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk]),
                         MemberAllergies(memberID: owen, firstName: "Owen", allergens: [.milk])]
        let offer = try #require(offers([item(chili)], on: night(home: [nora: true, owen: false]),
                                        allergies: allergies).first)
        #expect(offer.flags.count == 1)
        #expect(offer.flags[0].summary.contains("Nora"))
        #expect(!offer.flags[0].summary.contains("Owen"), "Owen's out that night")
    }

    @Test func aPastNightIsLoggingWhatWasEatenSoDislikesDoNotApply() {
        let frozen = item(chili)
        let past = night(-1, home: [nora: true])
        #expect(offers([frozen], on: past, notForMe: [chili.id: [nora: 1]], today: sunday).count == 1)
    }
}

struct FreezerTextTests {
    @Test func theAgeIsADateAndHowLongAgo() {
        let today = sunday
        let label = DayCardText.dateLabel(for: sunday.adding(days: -27))
        #expect(FreezerStash.madeText(sunday.adding(days: -27), today: today) == "Made \(label) · 3 weeks ago")
        #expect(FreezerStash.madeText(sunday.adding(days: -3), today: today).hasSuffix("3 days ago"))
        #expect(FreezerStash.madeText(sunday.adding(days: -1), today: today).hasSuffix("yesterday"))
        #expect(FreezerStash.madeText(sunday, today: today).hasSuffix("today"))
        #expect(FreezerStash.madeText(sunday.adding(days: -120), today: today).hasSuffix("4 months ago"))
    }

    @Test func aDateThatReadsAheadOfTodaySaysOnlyTheDate() {
        let later = sunday.adding(days: 2)
        #expect(FreezerStash.madeText(later, today: sunday) == "Made \(DayCardText.dateLabel(for: later))")
    }

    @Test func theCardSaysWhereItCameFrom() {
        let day = sunday.adding(days: -27)
        #expect(FreezerStash.reason(madeOn: day, today: sunday) == "From the freezer, made \(DayCardText.dateLabel(for: day))")
        #expect(FreezerStash.reason(madeOn: day, today: sunday).unicodeScalars.count <= 80, "the night's reason limit")
    }

    @Test func aDishTheFamilyVotedOutIsExplainedOnTheList() {
        #expect(FreezerStash.notOfferedNote(for: LibraryMeal.fixture(status: .retired))?.contains("voted") == true)
        #expect(FreezerStash.notOfferedNote(for: LibraryMeal.fixture(status: .archived))?.contains("archived") == true)
        #expect(FreezerStash.notOfferedNote(for: LibraryMeal.fixture(status: .active)) == nil)
        #expect(FreezerStash.notOfferedNote(for: nil) == nil)
    }

    @Test func aDishWeCantReadSaysAllergiesArentChecked() {
        #expect(FreezerStash.allergyUnknownNote(for: nil, isLoading: false)?.contains("allergies") == true)
        #expect(FreezerStash.allergyUnknownNote(for: nil, isLoading: true) == nil, "still loading")
        #expect(FreezerStash.allergyUnknownNote(for: LibraryMeal.fixture(), isLoading: false) == nil)
    }

    @Test func aStateAnOlderBuildDoesntKnowReadsAsGone() throws {
        let json = """
        {"id": "\(UUID())", "meal_id": "\(UUID())", "made_on": "2037-10-01", "state": "defrosting",
         "meals": {"name": "Chili"}, "plan_nights": []}
        """
        let item = try JSONDecoder().decode(FreezerItem.self, from: Data(json.utf8))
        #expect(item.state == .archived)
        #expect(item.mealName == "Chili")
    }

    @Test func aPlannedItemKnowsItsNight() throws {
        let json = """
        {"id": "\(UUID())", "meal_id": "\(UUID())", "made_on": "2037-10-01", "state": "used",
         "meals": {"name": "Chili"}, "plan_nights": [{"date": "2037-11-03"}]}
        """
        let item = try JSONDecoder().decode(FreezerItem.self, from: Data(json.utf8))
        #expect(item.plannedOn == sunday.adding(days: 2))
    }
}

@MainActor
struct FreezerStoreTests {
    private let chili = LibraryMeal.fixture(name: "Chili")

    @Test func itemsSortIntoInPlannedAndGoneByTheHouseholdsDay() async {
        let inside = item(chili), planned = item(chili, state: .used, plannedOn: sunday), used = item(chili, state: .used)
        let tossed = item(chili, state: .archived), eaten = item(chili, state: .used, plannedOn: sunday.adding(days: -3))
        let store = FreezerStore(householdID: Household.sample.id,
                                 client: .fake(items: { _ in [inside, planned, used, tossed, eaten] }))
        await store.load()
        #expect(store.inTheFreezer.map(\.id) == [inside.id])
        #expect(store.planned(today: sunday).map(\.id) == [planned.id])
        #expect(Set(store.gone(today: sunday).map(\.id)) == [used.id, tossed.id, eaten.id], "a plan from last week isn't still planned")
    }

    @Test func anOlderLoadFinishingLastIsIgnored() async {
        let old = item(chili), fresh = item(chili)
        let calls = Mutex(0)
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let store = FreezerStore(householdID: Household.sample.id, client: .fake(items: { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            guard call == 1 else { return [fresh] }
            parkedSignal.yield()
            for await _ in gate {}
            return [old]
        }))
        let slow = Task { await store.load() }
        for await _ in parked { break }
        await store.load()
        release.finish()
        await slow.value
        #expect(store.items.map(\.id) == [fresh.id])
    }

    @Test func addingSendsTheDishAndDateAndReloads() async {
        let sent = Mutex<(UUID, CalendarDay)?>(nil)
        let added = item(chili)
        let store = FreezerStore(householdID: Household.sample.id, client: .fake(
            items: { _ in sent.withLock { $0 == nil } ? [] : [added] },
            add: { _, meal, made in sent.withLock { $0 = (meal, made) } }
        ))
        #expect(await store.add(mealID: chili.id, madeOn: sunday))
        #expect(sent.withLock { $0?.0 } == chili.id)
        #expect(store.items.map(\.id) == [added.id])
    }

    @Test func somethingGoneOnAnotherPhoneSaysSoAndShowsTheLatest() async {
        let gone = item(chili, state: .used)
        let stale = FreezerItem(id: gone.id, mealID: gone.mealID, mealName: gone.mealName, madeOn: gone.madeOn, state: .in,
                                plannedOn: nil)
        let refused = Mutex(false)
        let store = FreezerStore(householdID: Household.sample.id, client: .fake(
            items: { _ in refused.withLock { $0 } ? [gone] : [stale] },
            setState: { _, _ in
                refused.withLock { $0 = true }
                throw PostgrestError(code: "FD002", message: "gone")
            }
        ))
        await store.load()
        await store.setState(.archived, item: stale)
        #expect(store.errorMessage?.contains("already") == true)
        #expect(store.errorMessage?.contains("connection") == false)
        #expect(store.inTheFreezer.isEmpty, "reloaded")
    }

    @Test func aFutureDateIsItsOwnMessage() async {
        let store = FreezerStore(householdID: Household.sample.id, client: .fake(
            add: { _, _, _ in throw PostgrestError(code: "22023", message: "future") }
        ))
        #expect(await !store.add(mealID: chili.id, madeOn: sunday))
        #expect(store.errorMessage?.contains("today") == true)
    }

    @Test func aFailedLoadSaysCheckYourConnection() async {
        let store = FreezerStore(householdID: Household.sample.id, client: .fake(items: { _ in throw URLError(.notConnectedToInternet) }))
        await store.load()
        #expect(store.errorMessage?.contains("connection") == true)
    }
}

@MainActor
struct FreezerSwapTests {
    private let chili = LibraryMeal.fixture(name: "Chili")

    private func store(_ nights: [WeekNight], use: @escaping @Sendable (UUID, UUID, String) async throws -> Void = { _, _, _ in })
        async -> WeekStore {
        let saved = Week(planID: UUID(), start: sunday, nights: nights)
        let store = WeekStore(householdID: Household.sample.id,
                              client: .fake(week: { _, _ in saved }, useFreezerItem: use), today: { sunday })
        await store.load(settings: HouseholdSettings())
        return store
    }

    @Test func pickingAStashItemPutsTheDishOnTheNightLocked() async throws {
        let target = night(2)
        let frozen = item(chili)
        let sent = Mutex<(UUID, UUID, String)?>(nil)
        let store = await store([target], use: { night, item, reason in sent.withLock { $0 = (night, item, reason) } })
        #expect(await store.swap(nightID: target.id, to: .freezer(frozen, reason: "From the freezer")))
        #expect(sent.withLock { $0?.1 } == frozen.id)
        let saved = try #require(store.week?.nights[0])
        #expect(saved.mealID == chili.id)
        #expect(saved.mealName == "Chili")
        #expect(saved.stashItemID == frozen.id)
        #expect(saved.locked)
        #expect(saved.reason == "From the freezer")
    }

    @Test func someoneElseGotThereFirstHasItsOwnMessage() async {
        let target = night(2)
        let store = await store([target], use: { _, _, _ in throw PostgrestError(code: "FD002", message: "gone") })
        #expect(await !store.swap(nightID: target.id, to: .freezer(item(chili), reason: "x")))
        #expect(store.errorMessage?.contains("freezer") == true)
        #expect(store.errorMessage?.contains("connection") == false)
        #expect(store.week?.nights[0].mealID == nil)
    }

    @Test func aDishThatCantGoOnTheNightHasItsOwnMessage() async {
        let target = night(2)
        let store = await store([target], use: { _, _, _ in throw PostgrestError(code: "FD003", message: "no") })
        #expect(await !store.swap(nightID: target.id, to: .freezer(item(chili), reason: "x")))
        #expect(store.errorMessage?.contains("connection") == false)
        #expect(store.errorMessage?.contains("can't go") == true)
    }

    @Test func swappingAStashNightClearsTheLinkAndReadsTheWeekBack() async throws {
        var frozen = night(2, meal: chili)
        frozen.stashItemID = UUID()
        let loads = Mutex(0)
        let saved = Week(planID: UUID(), start: sunday, nights: [frozen])
        var after = saved
        after.nights[0].mealID = nil
        after.nights[0].mealName = nil
        after.nights[0].quickPick = .takeout
        after.nights[0].stashItemID = nil
        let written = after
        let swapped = Mutex(false)
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in
                loads.withLock { $0 += 1 }
                return swapped.withLock { $0 } ? written : saved
            },
            setNight: { _, _ in swapped.withLock { $0 = true } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let before = loads.withLock { $0 }
        #expect(await store.swap(nightID: frozen.id, to: .quickPick(.takeout)))
        #expect(loads.withLock { $0 } == before + 1)
        #expect(store.week?.nights[0].stashItemID == nil)
    }
}

extension FreezerClient {
    static func fake(
        items: @escaping @Sendable (UUID) async throws -> [FreezerItem] = { _ in [] },
        add: @escaping @Sendable (UUID, UUID, CalendarDay) async throws -> Void = { _, _, _ in },
        setState: @escaping @Sendable (UUID, FreezerItem.State) async throws -> Void = { _, _ in }
    ) -> FreezerClient {
        FreezerClient(items: items, add: add, setState: setState)
    }
}
