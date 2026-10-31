import Foundation
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let noRead = URLError(.notConnectedToInternet)

private func night(_ offset: Int = 1, meal: LibraryMeal? = nil, pick: QuickPick? = nil, leftoversFrom: UUID? = nil,
                   home: [UUID: Bool] = [:]) -> WeekNight {
    WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: "18:00", mealID: meal?.id,
              mealName: meal?.name, quickPick: pick, locked: false, attendance: home, leftoversFrom: leftoversFrom)
}

@MainActor
private func allergyTexts(_ target: WeekNight, nights: [WeekNight]? = nil, store: LibraryStore) -> [String] {
    WeekStore.planCard(for: target, nights: nights ?? [target], members: [], library: store.meals, allergies: store.allergies,
                       settings: HouseholdSettings(), today: sunday, minuteNow: 0, lookup: store.lookup)
        .badges.compactMap { badge in
            switch badge {
            case .allergy(let text), .allergyUnchecked(let text): text
            default: nil
            }
        }
}

/// Another phone changed the family or a dish. These go through the store, as This Week does.
@MainActor
struct AnotherPhoneChangedSomethingTests {
    private let owen = Member.fixture(firstName: "Owen")
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])

    private func store(rows: [AllergyRow]) -> LibraryStore {
        let mac = mac
        return LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in [mac] }, allergies: { _ in rows }))
    }

    private var noraMilk: [AllergyRow] { [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)] }

    @Test func aMemberAddedElsewhereIsFlaggedEverywhereAfterARefresh() async {
        let store = store(rows: noraMilk)
        await store.load(members: [owen])
        #expect(store.allergies.isEmpty, "this phone hadn't heard of her")

        await store.refreshReactions(members: [owen, nora])

        let noRow = night(meal: mac, home: [owen.id: true])
        #expect(allergyTexts(noRow, store: store) == ["Contains milk (Nora)"])
        #expect(PlanIt.allergyCheck(for: mac, on: noRow, library: store.meals, allergies: store.allergies, lookup: store.lookup).texts
                == ["Contains milk (Nora)"])
        #expect(SwapRow.allergyCheck(mac, on: noRow, library: store.meals, allergies: store.allergies, lookup: store.lookup).texts
                == ["Contains milk (Nora)"])
        let list = WeeklyList.build(nights: DoubleIt.listNights(WeekLayout(nights: [noRow], today: sunday), library: store.meals,
                                                                allergies: store.allergies),
                                    library: store.meals, allergies: store.allergies)
        #expect(list.first?.note?.contains("Nora") == true)
    }

    @Test func aMemberRemovedElsewhereStopsBeingFlagged() async {
        let store = store(rows: noraMilk)
        await store.load(members: [owen, nora])
        var gone = nora
        gone.status = .removed
        await store.refreshReactions(members: [owen, gone])
        #expect(allergyTexts(night(meal: mac, home: [owen.id: true]), store: store).isEmpty)
    }

    @Test func aMemberRemovedElsewhereGoesEvenIfTheAllergiesCantBeRead() async {
        let reads = Mutex(0)
        let rows = noraMilk, mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in [mac] }, allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw noRead }
            return rows
        }))
        await store.load(members: [owen, nora])
        var gone = nora
        gone.status = .removed
        await store.refreshReactions(members: [owen, gone])
        #expect(store.allergies.isEmpty)
    }

    @Test func aRunningLoadFinishesWithTheLatestMembers() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let rows = noraMilk, mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            signal.yield()
            for await _ in gate { break }
            return [mac]
        }, allergies: { _ in rows }))
        let owen = owen, nora = nora
        let running = Task { await store.load(members: [owen]) }
        for await _ in parked { break }
        await store.refreshReactions(members: [owen, nora])
        release.yield()
        release.finish()
        await running.value
        #expect(store.allergies.map(\.memberID) == [nora.id])
    }

    @Test func ingredientsEditedElsewhereReachTheCardOnARefresh() async {
        let edited = Mutex(false)
        let plain = LibraryMeal.fixture(name: "Toast", ingredients: ["bread"])
        var withMilk = plain
        withMilk.ingredients = LibraryMeal.fixture(ingredients: ["milk"]).ingredients
        let rows = noraMilk, updated = withMilk
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            edited.withLock { $0 } ? [updated] : [plain]
        }, allergies: { _ in rows }))
        await store.load(members: [nora])
        let target = night(meal: plain, home: [nora.id: true])
        #expect(allergyTexts(target, store: store).isEmpty)
        edited.withLock { $0 = true }
        await store.refreshReactions(members: [nora])
        #expect(allergyTexts(target, store: store) == ["Contains milk (Nora)"])
    }

    @Test func aRefreshThatCantReadTheDishesKeepsThem() async {
        let reads = Mutex(0)
        let mac = mac, rows = noraMilk
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw noRead }
            return [mac]
        }, allergies: { _ in rows }))
        await store.load(members: [nora])
        await store.refreshReactions(members: [nora])
        #expect(store.meals.map(\.id) == [mac.id])
        #expect(store.allergies.count == 1)
    }

    @Test func allergiesReadStillCountWhenTheReactionsFail() async {
        let offline = Mutex(false)
        let reads = Mutex(0)
        let mac = mac, rows = noraMilk
        var client = LibraryClient.fake(meals: { _ in [mac] }, allergies: { _ in
            reads.withLock { $0 += 1; return $0 } == 1 ? [] : rows
        })
        client.verdicts = { _ in
            if offline.withLock({ $0 }) { throw noRead }
            return []
        }
        let store = LibraryStore(householdID: Household.sample.id, client: client)
        await store.load(members: [nora])
        offline.withLock { $0 = true }
        await store.refreshReactions(members: [nora])
        #expect(store.allergies.map(\.memberID) == [nora.id])
    }

    @Test func anArchiveWhileARefreshIsOutStands() async {
        let server = FakeMealServer(meal: mac, parkOnRead: 2)
        let store = LibraryStore(householdID: Household.sample.id, client: server.client)
        await store.load(members: [])
        let refresh = Task { await store.refreshReactions(members: []) }
        await server.waitUntilParked()
        await store.setArchived(true, mealID: mac.id)
        server.release()
        await refresh.value
        #expect(store.meal(mac.id)?.status == .archived, "the read started before the archive")
    }
}

/// The note says to pull down, so a pull has to be able to find the dish.
@MainActor
struct WhenTheLibraryLoadsTests {
    private let mac = LibraryMeal.fixture(name: "Mac")

    private func loaded() async -> LibraryStore {
        let mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in [mac] }))
        await store.load(members: [])
        return store
    }

    @Test func aFirstLoadIsNeeded() {
        let store = LibraryStore(householdID: Household.sample.id, client: .fake())
        #expect(store.needsFullLoad(holding: []))
    }

    @Test func aKnownDishNeedsNoFullLoadAndAnUnknownOneDoes() async {
        let store = await loaded()
        #expect(!store.needsFullLoad(holding: [mac.id]))
        #expect(store.needsFullLoad(holding: [mac.id, UUID()]))
    }

    @Test func aFailedReloadIsTriedAgain() async {
        let reads = Mutex(0)
        let mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw noRead }
            return [mac]
        }))
        await store.load(members: [])
        await store.load(members: [])
        #expect(store.needsFullLoad(holding: [mac.id]))
    }

    /// The week read after the first decision can bring a dish this phone hasn't read: one pull has to be enough.
    @Test func aDishTheWeekJustBroughtGetsALoadAfterAll() async {
        let store = await loaded()
        #expect(store.needsLoad(afterFullLoad: false, holding: [UUID()]))
        #expect(!store.needsLoad(afterFullLoad: false, holding: [mac.id]))
        #expect(store.needsLoad(afterFullLoad: true, holding: [UUID()]), "the load ran alongside the week and may have missed it")
        #expect(!store.needsLoad(afterFullLoad: true, holding: [mac.id]))
    }

    @Test func aLoadThatJustFailedWaitsForTheNextPull() async {
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in throw noRead }))
        await store.load(members: [])
        #expect(!store.needsLoad(afterFullLoad: true, holding: [UUID()]))
    }

    @Test func planItStartsALoadOnlyWhenThereIsntOneToWaitFor() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            signal.yield()
            for await _ in gate { break }
            return [mac]
        }))
        #expect(store.shouldStartLoad(holding: [mac.id]))
        let running = Task { await store.load(members: []) }
        for await _ in parked { break }
        #expect(!store.shouldStartLoad(holding: [mac.id]))
        release.yield()
        release.finish()
        await running.value
        #expect(!store.shouldStartLoad(holding: [mac.id]))
        #expect(store.shouldStartLoad(holding: [UUID()]))
    }
}

/// Only the newest load's answer counts. An older read can predate a save, so it's never trusted.
@MainActor
struct AReplacedLoadTests {
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)

    /// The older load read before the save and the newer one failed: what was saved stays, and it says it couldn't check.
    @Test func anOlderReadCantUndoASavedAllergyOrHideAFailure() async {
        let mac = mac
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw noRead }
            signal.yield()
            for await _ in gate { break }
            return [mac]
        }))
        let nora = nora
        let older = Task { await store.load(members: [nora]) }
        for await _ in parked { break }
        await store.showAllergies(AllergyChoice(allergens: [.milk]), for: nora, members: [nora])
        release.yield()
        release.finish()
        await older.value
        #expect(store.allergies.first?.allergens == [.milk], "the save stands")
        #expect(store.lookup == .failed, "the newest load failed")
        #expect(store.lastLoadFailed)
    }

    /// Closing Swap can cancel the load that replaced This Week's. The note is true, and one pull fixes it.
    @Test func aCancelledReplacementSaysCouldntCheckUntilThePull() async {
        let mac = mac
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 2 { throw CancellationError() }
            if read == 1 {
                signal.yield()
                for await _ in gate { break }
            }
            return [mac]
        }))
        let first = Task { await store.load(members: []) }
        for await _ in parked { break }
        await store.load(members: [])
        release.yield()
        release.finish()
        await first.value
        #expect(store.lookup == .failed)
        #expect(store.needsFullLoad(holding: [mac.id]))
        await store.load(members: [])
        #expect(store.lookup == .loaded)
        #expect(store.meals.map(\.id) == [mac.id])
    }

    /// An older answer never replaces a newer one.
    @Test func anOlderAnswerStaysOutOnceANewerOneIsIn() async {
        let newer = LibraryMeal.fixture(name: "Newer")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        let mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 2 { return [newer] }
            signal.yield()
            for await _ in gate { break }
            return [mac]
        }))
        let older = Task { await store.load(members: []) }
        for await _ in parked { break }
        await store.load(members: [])
        #expect(store.lookup == .loaded, "the newer answer is in, whatever the older load is doing")
        release.yield()
        release.finish()
        await older.value
        #expect(store.meals.map(\.id) == [newer.id])
    }

    /// That load read the dish before the archive, but it's also the only news about allergies and ingredients: read again.
    @Test func anArchiveWhileALoadIsOutStandsAndStillGetsAnAnswer() async {
        let server = FakeMealServer(meal: mac, parkOnRead: 2)
        let store = LibraryStore(householdID: Household.sample.id, client: server.client)
        await store.load(members: [nora])
        server.edit { $0.ingredients = LibraryMeal.fixture(ingredients: ["peanut butter"]).ingredients }
        let reload = Task { await store.load(members: [nora]) }
        await server.waitUntilParked()
        await store.setArchived(true, mealID: mac.id)
        server.release()
        await reload.value
        #expect(store.meal(mac.id)?.status == .archived)
        #expect(store.meal(mac.id)?.ingredients.map(\.name) == ["peanut butter"], "the answer wasn't thrown away")
        #expect(store.lookup == .loaded)
    }

    @Test func anArchiveWithNothingOutReadsNothing() async {
        let server = FakeMealServer(meal: mac, parkOnRead: 99)
        let store = LibraryStore(householdID: Household.sample.id, client: server.client)
        await store.load(members: [])
        await store.setArchived(true, mealID: mac.id)
        #expect(server.reads == 1)
    }

    /// `lookup` says `.loaded` only if the newest load's answer was applied.
    @Test func aCancelledReloadIsntLoadedThoughThereIsOldData() async {
        let mac = mac
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 2 { throw CancellationError() }
            return [mac]
        }))
        await store.load(members: [])
        #expect(store.lookup == .loaded)
        await store.load(members: [])
        #expect(store.hasLoaded)
        #expect(store.lookup == .failed)
        #expect(store.needsFullLoad(holding: [mac.id]))
        #expect(!store.needsLoad(afterFullLoad: true, holding: [UUID()]), "it waits for the next pull")
        #expect(store.errorMessage == nil, "a cancel isn't something to tell anyone about")
        #expect(!store.lastLoadFailed)
        #expect(store.meals.map(\.id) == [mac.id], "what it read stays")
        await store.load(members: [])
        #expect(store.lookup == .loaded)
    }

    @Test func aMissingDishAfterACancelledReloadSaysSo() async {
        let mac = mac
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 2 { throw CancellationError() }
            return [mac]
        }))
        await store.load(members: [])
        await store.load(members: [])
        let missing = WeekNight(id: UUID(), date: sunday.adding(days: 1), effort: .normal, dinnerTime: nil, mealID: UUID(),
                                mealName: "New", quickPick: nil, locked: false, attendance: [:])
        #expect(allergyTexts(missing, store: store) == [FreezerStash.allergyUnknownNote(for: nil, isLoading: false)])
    }

    @Test func aFailureThenACancelledReplacementIsntLoaded() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        let mac = mac
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 1 { return [mac] }
            if read == 3 { throw CancellationError() }
            signal.yield()
            for await _ in gate { break }
            throw noRead
        }))
        await store.load(members: [])
        let second = Task { await store.load(members: []) }
        for await _ in parked { break }
        await store.load(members: [])
        release.yield()
        release.finish()
        await second.value
        #expect(store.lookup == .failed)
    }
}

/// A server for one dish: a read sees the dish as it was when the read started, however long it takes to come back.
private final class FakeMealServer: Sendable {
    private let dish: Mutex<LibraryMeal>
    private let readCount = Mutex(0)
    private let parkOnRead: Int
    private let gate: AsyncStream<Void>
    private let open: AsyncStream<Void>.Continuation
    private let parked: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init(meal: LibraryMeal, parkOnRead: Int) {
        dish = Mutex(meal)
        self.parkOnRead = parkOnRead
        (gate, open) = AsyncStream<Void>.makeStream()
        (parked, signal) = AsyncStream<Void>.makeStream()
    }

    var reads: Int { readCount.withLock { $0 } }

    var client: LibraryClient {
        .fake(meals: { [self] _ in
            let read = readCount.withLock { $0 += 1; return $0 }
            let seen = dish.withLock { $0 }
            if read == parkOnRead {
                signal.yield()
                for await _ in gate { break }
            }
            return [seen]
        }, setStatus: { [self] _, status in
            dish.withLock { $0.status = status }
        })
    }

    func edit(_ change: (inout LibraryMeal) -> Void) { dish.withLock { change(&$0) } }

    func waitUntilParked() async {
        for await _ in parked { break }
    }

    func release() {
        open.yield()
        open.finish()
    }
}

/// The card and the list that buys the food count the same people.
struct TheListMatchesTheCardTests {
    private let nora = UUID(), owen = UUID()
    private var allergies: [MemberAllergies] { [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])] }
    private let chili = LibraryMeal.fixture(name: "Chili", tags: [.leftovers], ingredients: ["cheddar"])
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["cheddar"])

    private func cheddarNote(_ nights: [WeekNight], library: [LibraryMeal]) -> String? {
        let layout = WeekLayout(nights: nights, today: sunday)
        return WeeklyList.build(nights: DoubleIt.listNights(layout, library: library, allergies: allergies), library: library,
                                allergies: allergies).first { $0.name == "cheddar" }?.note
    }

    /// Where Build puts leftovers: the night after a big batch, with no link.
    @Test func unlinkedLeftoversAfterABigBatchCount() {
        let monday = night(1, meal: chili, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, home: [nora: true, owen: true])
        #expect(cheddarNote([monday, tuesday], library: [chili])?.contains("Nora") == true)
    }

    @Test func itDoesntDoubleTheAmounts() {
        let monday = night(1, meal: chili, home: [owen: true])
        let tuesday = night(2, pick: .leftovers, home: [owen: true])
        let nights = DoubleIt.listNights(WeekLayout(nights: [monday, tuesday], today: sunday), library: [chili], allergies: [])
        #expect(nights.allSatisfy { !$0.doubled }, "nobody said to cook twice as much")
    }

    @Test func leftoversAfterAnUntaggedDishStayQuiet() {
        let monday = night(1, meal: mac, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, home: [nora: true, owen: true])
        #expect(cheddarNote([monday, tuesday], library: [mac]) == nil, "the same as its card: they could be from anything")
    }

    @Test func leftoversLaterInTheWeekDontCount() {
        let monday = night(1, meal: chili, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .takeout, home: [nora: false])
        let wednesday = night(3, pick: .leftovers, home: [nora: true])
        #expect(cheddarNote([monday, tuesday, wednesday], library: [chili]) == nil)
    }

    @Test func noRowOnThoseLeftoversCountsToo() {
        let monday = night(1, meal: chili, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, home: [owen: true])
        #expect(cheddarNote([monday, tuesday], library: [chili])?.contains("Nora") == true)
    }
}

struct SwapRowTests {
    private let nora = UUID(), owen = UUID()
    private var allergies: [MemberAllergies] { [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])] }
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])

    @Test func itCountsWhoeversHomeThatNight() {
        let out = night(home: [nora: false, owen: true])
        #expect(SwapRow.allergyCheck(mac, on: out, library: [mac], allergies: allergies, lookup: .loaded) == AllergyCheck())
        #expect(SwapRow.allergyCheck(mac, on: night(home: [nora: true]), library: [mac], allergies: allergies, lookup: .loaded).texts
                == ["Contains milk (Nora)"])
    }

    /// The night has gone from under the sheet, so nobody knows who's home: warn rather than stay quiet.
    @Test func noNightCountsEveryone() {
        #expect(SwapRow.allergyCheck(mac, on: nil, library: [mac], allergies: allergies, lookup: .loaded).texts
                == ["Contains milk (Nora)"])
        let dish = CatalogDish.fixture(name: "Mac", ingredients: ["milk"])
        #expect(SwapRow.allergyCheck(catalog: dish, on: nil, allergies: allergies).texts == ["Contains milk (Nora)"])
    }

    @Test func aCatalogDishCountsWhoeversHome() {
        let dish = CatalogDish.fixture(name: "Mac", ingredients: ["milk"])
        #expect(SwapRow.allergyCheck(catalog: dish, on: night(home: [nora: false]), allergies: allergies) == AllergyCheck())
        #expect(SwapRow.allergyCheck(catalog: dish, on: night(home: [owen: true]), allergies: allergies).texts
                == ["Contains milk (Nora)"], "no row for her")
    }

    @Test func voiceOverReadsTheDishThenAllergiesThenTheRest() {
        let flagged = SwapRow.allergyCheck(mac, on: nil, library: [mac], allergies: allergies, lookup: .loaded)
        #expect(SwapRow.label("Mac", allergies: flagged, details: ["Quick"]) == "Mac, Contains milk (Nora), Quick")
        #expect(SwapRow.label("Mac", allergies: AllergyCheck()) == "Mac")
        #expect(SwapRow.label("Mac", allergies: AllergyCheck(note: "Can't check")) == "Mac, Can't check")
    }
}
