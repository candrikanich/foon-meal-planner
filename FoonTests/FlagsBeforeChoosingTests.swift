import Foundation
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let noRead = URLError(.notConnectedToInternet)

private func night(_ offset: Int = 1, meal: LibraryMeal? = nil, mealID: UUID? = nil, pick: QuickPick? = nil,
                   leftoversFrom: UUID? = nil, stash: UUID? = nil, home: [UUID: Bool] = [:]) -> WeekNight {
    WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: "18:00",
              mealID: meal?.id ?? mealID, mealName: meal?.name ?? mealID.map { _ in "Someone's new dish" }, quickPick: pick,
              locked: false, attendance: home, leftoversFrom: leftoversFrom, stashItemID: stash)
}

@MainActor
private func card(_ target: WeekNight, week: [WeekNight]? = nil, library: [LibraryMeal] = [],
                  allergies: [MemberAllergies] = [], lookup: LibraryLookup, isAway: Bool = false) -> DayCardModel {
    WeekStore.planCard(for: target, nights: week ?? [target], members: [], library: library, allergies: allergies,
                       settings: HouseholdSettings(), today: sunday, minuteNow: 0, isAway: isAway, lookup: lookup)
}

@MainActor
private func card(_ target: WeekNight, week: [WeekNight]? = nil, store: LibraryStore) -> DayCardModel {
    card(target, week: week, library: store.meals, allergies: store.allergies, lookup: store.lookup)
}

private let unknownNote = FreezerStash.allergyUnknownNote(for: nil, isLoading: false)!

private func allergyTexts(_ card: DayCardModel) -> [String] {
    card.badges.compactMap { badge in
        switch badge {
        case .allergy(let text), .allergyUnchecked(let text): text
        default: nil
        }
    }
}

/// A store whose first read of the meals waits at a gate, so a test can look at it mid-load.
@MainActor
private struct GatedLoad {
    let store: LibraryStore
    let parked: AsyncStream<Void>
    let release: AsyncStream<Void>.Continuation

    init(meals: [LibraryMeal], allergies: [AllergyRow] = [], laterReads: Result<[LibraryMeal], URLError>? = nil,
         firstReadGated: Bool = true) {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            let read = reads.withLock { $0 += 1; return $0 }
            if read == (firstReadGated ? 1 : 2) {
                signal.yield()
                for await _ in gate { break }
            }
            if read > 1, let laterReads { return try laterReads.get() }
            return meals
        }, allergies: { _ in allergies }))
        (self.parked, self.release) = (parked, release)
    }

    func finish() {
        release.yield()
        release.finish()
    }
}

@MainActor
struct LibraryLookupTests {
    private let chili = LibraryMeal.fixture(name: "Chili")

    @Test func beforeAnyLoadItsWaiting() {
        let store = LibraryStore(householdID: Household.sample.id, client: .fake())
        #expect(store.lookup == .loading, "This Week's cards can draw before the library's load has begun")
    }

    @Test func whileALoadRunsItsWaitingThenItDecides() async {
        let load = GatedLoad(meals: [chili])
        let running = Task { await load.store.load(members: []) }
        for await _ in load.parked { break }
        #expect(load.store.lookup == .loading)
        load.finish()
        await running.value
        #expect(load.store.lookup == .loaded)
    }

    @Test func aFailedLoadHasFailedUntilARetryWorks() async {
        let attempts = Mutex(0)
        let chili = chili
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw noRead }
            return [chili]
        }))
        await store.load(members: [])
        #expect(store.lookup == .failed)
        await store.load(members: [])
        #expect(store.lookup == .loaded)
    }

    /// Swap can replace This Week's running load with its own, then close: nothing's coming, and This Week is still up.
    @Test func aCancelledLoadWithNothingRunningDoesntWaitForever() async {
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in throw CancellationError() }))
        await store.load(members: [])
        #expect(store.lookup == .failed)
    }

    @Test func aReloadWaitsAndAFailedOneSaysSo() async {
        let load = GatedLoad(meals: [chili], laterReads: .failure(noRead), firstReadGated: false)
        await load.store.load(members: [])
        let running = Task { await load.store.load(members: []) }
        for await _ in load.parked { break }
        #expect(load.store.lookup == .loading)
        load.finish()
        await running.value
        #expect(load.store.lookup == .failed, "what it read earlier may be out of date")
        #expect(load.store.lastLoadFailed)
        #expect(!load.store.meals.isEmpty, "and it's still there to read")
    }
}

/// #157: a card holding a dish it can't look up says so, and "no flag" never reads as "nothing to worry about".
@MainActor
struct CardWithAnUnknownDishTests {
    private let nora = UUID(), owen = UUID()
    private var noraAllergies: [MemberAllergies] { [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])] }
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])

    private func failedStore() async -> LibraryStore {
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in throw noRead }))
        await store.load(members: [])
        return store
    }

    @Test func aFailedLoadSaysItCouldntCheckAndVoiceOverReadsIt() async {
        let store = await failedStore()
        let model = card(night(meal: mac, home: [nora: true]), store: store)
        #expect(model.badges == [.allergyUnchecked(unknownNote)])
        #expect(DayCardText.accessibilitySummary(model, today: sunday).contains(unknownNote))
    }

    @Test func aFailedLoadSaysSoWhoeversHomeBecauseItDoesntKnowTheirAllergies() async {
        let store = await failedStore()
        #expect(card(night(meal: mac, home: [owen: true]), store: store).badges == [.allergyUnchecked(unknownNote)])
        #expect(card(night(meal: mac), store: store).badges == [.allergyUnchecked(unknownNote)])
    }

    @Test func whileLoadingItSaysNothingThenFlagsWhatItFinds() async {
        let nora = Member.fixture(firstName: "Nora")
        let mac = mac
        let load = GatedLoad(meals: [mac], allergies: [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)])
        let target = night(meal: mac, home: [nora.id: true])
        #expect(card(target, store: load.store).badges.isEmpty, "not started yet: no false warning")
        let running = Task { await load.store.load(members: [nora]) }
        for await _ in load.parked { break }
        #expect(card(target, store: load.store).badges.isEmpty, "still loading: no false warning")
        load.finish()
        await running.value
        #expect(card(target, store: load.store).badges == [.allergy("Contains milk (Nora)")])
    }

    @Test func whileLoadingThenFailingItSaysSoOnlyOnceItKnows() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (parked, signal) = AsyncStream<Void>.makeStream()
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            signal.yield()
            for await _ in gate { break }
            throw noRead
        }))
        let target = night(meal: mac, home: [nora: true])
        let running = Task { await store.load(members: []) }
        for await _ in parked { break }
        #expect(card(target, store: store).badges.isEmpty)
        release.yield()
        release.finish()
        await running.value
        #expect(card(target, store: store).badges == [.allergyUnchecked(unknownNote)])
    }

    @Test func aReloadStillShowsTheFlagsOfADishItCanFind() {
        let model = card(night(meal: mac, home: [nora: true]), library: [mac], allergies: noraAllergies, lookup: .loading)
        #expect(model.badges == [.allergy("Contains milk (Nora)")])
    }

    /// Another phone planned a dish this one hasn't read.
    @Test func aLoadedLibraryMissingTheDishSaysSoWhenItMatters() {
        let new = UUID()
        #expect(card(night(mealID: new, home: [nora: true]), allergies: noraAllergies, lookup: .loaded).badges
                == [.allergyUnchecked(unknownNote)])
        #expect(card(night(mealID: new, home: [nora: false, owen: true]), allergies: noraAllergies, lookup: .loaded).badges.isEmpty,
                "the one with allergies is out")
        #expect(card(night(mealID: new, home: [owen: true]), allergies: [], lookup: .loaded).badges.isEmpty,
                "a family with none recorded never hears about it")
        #expect(card(night(mealID: new, home: [nora: true]), allergies: noraAllergies, lookup: .loading).badges.isEmpty,
                "a reload is running: it may be about to find it")
    }

    /// The allergies it read last time say nobody home has any, but they may be old: a parent may have added one since.
    @Test func afterAFailedReloadAMissingDishSaysSoAndAFoundOneKeepsItsFlags() async {
        let nora = Member.fixture(firstName: "Nora")
        let mac = mac
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw noRead }
            return [mac]
        }, allergies: { _ in [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)] }))
        await store.load(members: [nora])
        await store.load(members: [nora])
        #expect(store.lastLoadFailed)
        #expect(card(night(mealID: UUID(), home: [nora.id: false, owen: true]), store: store).badges
                == [.allergyUnchecked(unknownNote)])
        #expect(card(night(meal: mac, home: [nora.id: true]), store: store).badges
                == [.allergy("Contains milk (Nora)"), .allergyUnchecked(AllergyMatcher.outOfDateNote)])
    }

    @Test func aFreezerNightSaysSo() {
        #expect(card(night(mealID: UUID(), stash: UUID(), home: [nora: true]), lookup: .failed).badges
                == [.allergyUnchecked(unknownNote)])
    }

    @Test func linkedLeftoversOfAnUnknownDishSaySo() {
        let monday = night(1, mealID: UUID(), home: [owen: true])
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id, home: [nora: true])
        let week = [monday, tuesday]
        #expect(card(tuesday, week: week, lookup: .failed).badges == [.allergyUnchecked(unknownNote)])
        #expect(card(tuesday, week: week, allergies: noraAllergies, lookup: .loaded).badges
                == [.allergyUnchecked(unknownNote)])
        #expect(card(tuesday, week: week, lookup: .loading).badges.isEmpty)
    }

    /// Build puts leftovers after a big batch, and only the library can say the dish was one.
    @Test func leftoversAfterADishItCantReadSaySo() {
        let monday = night(1, mealID: UUID(), home: [nora: true])
        let tuesday = night(2, pick: .leftovers, home: [nora: true])
        #expect(card(tuesday, week: [monday, tuesday], lookup: .failed).badges == [.allergyUnchecked(unknownNote)])
    }

    @Test func leftoversThatNameNoDishStaySilent() {
        let plain = night(1, meal: mac, home: [nora: true])
        let tuesday = night(2, pick: .leftovers, home: [nora: true])
        #expect(card(tuesday, week: [plain, tuesday], library: [mac], allergies: noraAllergies, lookup: .loaded).badges.isEmpty,
                "Mac isn't a big batch, so these leftovers could be anything")
        let lone = night(1, pick: .leftovers, home: [nora: true])
        #expect(card(lone, lookup: .failed).badges.isEmpty, "nothing before it to have been left over")
        let afterTakeout = [night(0, pick: .takeout), lone]
        #expect(card(lone, week: afterTakeout, lookup: .failed).badges.isEmpty)
    }

    @Test(arguments: [QuickPick.takeout, .eatOut, .fendForYourselves, .freezerRaid, .leftovers])
    func aQuickPickNamesNoDish(pick: QuickPick) {
        #expect(card(night(pick: pick, home: [nora: true]), lookup: .failed).badges.isEmpty)
    }

    @Test func anEmptyNightSaysNothing() {
        #expect(card(night(home: [nora: true]), lookup: .failed).badges.isEmpty)
    }

    @Test func anAwayNightSaysNothing() {
        #expect(card(night(mealID: UUID(), home: [nora: true]), lookup: .failed, isAway: true).badges.isEmpty)
    }

}

/// Swap and Plan it read the card's rule: a dish shows, before it's chosen, what its card would say once it is.
@MainActor
struct FlagsBeforeChoosingTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)
    private let caesar = LibraryMeal.fixture(name: "Caesar", ingredients: ["parmesan"])
    private let spaghettiID = UUID()
    private var spaghetti: LibraryMeal {
        var meal = LibraryMeal.fixture(id: spaghettiID, name: "Spaghetti", ingredients: ["pasta"])
        meal.sides = [.meal(caesar.id)]
        return meal
    }
    private let bare = LibraryMeal.fixture(name: "Grandma's special")
    private var noraAllergies: [MemberAllergies] { [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.milk])] }

    private func check(_ dish: LibraryMeal?, library: [LibraryMeal], allergies: [MemberAllergies]? = nil, on target: WeekNight,
                       lookup: LibraryLookup = .loaded) -> AllergyCheck {
        NightBadges.allergyCheck(dish: dish, library: library, allergies: allergies ?? noraAllergies, home: target.allergyHome(allergies ?? noraAllergies),
                                 lookup: lookup)
    }

    @Test func aSidesIngredientsFlagTheDish() {
        let tonight = night(meal: spaghetti, home: [nora.id: true])
        #expect(check(spaghetti, library: [spaghetti, caesar], on: tonight).texts == ["Contains milk (Nora)"])
    }

    @Test func itNamesOnlyWhoeversHomeThatNight() {
        let library = [spaghetti, caesar]
        #expect(check(spaghetti, library: library, on: night(home: [nora.id: true, owen.id: false])).flags.count == 1)
        #expect(check(spaghetti, library: library, on: night(home: [nora.id: false, owen.id: true])) == AllergyCheck())
    }

    @Test func aBareDishSaysItCantBeChecked() {
        let said = check(bare, library: [bare], on: night(home: [nora.id: true]))
        #expect(said.flags.isEmpty)
        #expect(said.note?.contains("allergies can't be checked") == true)
        #expect(check(bare, library: [bare], on: night(home: [nora.id: false, owen.id: true])) == AllergyCheck())
    }

    /// The promise: what Swap and Plan it say is what the card says once it's chosen, whoever's home.
    @Test(arguments: [(true, false), (false, true), (true, true), (false, false)])
    func whatsShownBeforeChoosingIsWhatTheCardSays(noraHome: Bool, owenHome: Bool) {
        let both = noraAllergies + [MemberAllergies(memberID: owen.id, firstName: "Owen", customTexts: ["parmesan"])]
        let library = [spaghetti, caesar, bare]
        let home = [nora.id: noraHome, owen.id: owenHome]
        for dish in [spaghetti, bare, caesar] {
            let target = night(meal: dish, home: home)
            let plannedCard = card(target, library: library, allergies: both, lookup: .loaded)
            #expect(check(dish, library: library, allergies: both, on: night(home: home)).texts == allergyTexts(plannedCard))
            let planIt = PlanIt.allergyCheck(for: dish, on: night(home: home), library: library, allergies: both, lookup: .loaded)
            #expect(planIt.texts == allergyTexts(plannedCard))
        }
    }

    /// Someone who eats separately still counts: the people cooking need to know. A removed member doesn't.
    @Test func eatsSeparatelyCountsAndRemovedDoesnt() async throws {
        var baby = Member.fixture(firstName: "Baby", ageGroup: .kid)
        baby.eatsSeparately = true
        let gone = Member.fixture(firstName: "Gone", status: .removed)
        let rows = [AllergyRow(memberID: baby.id, allergen: .milk, customText: nil),
                    AllergyRow(memberID: gone.id, allergen: .milk, customText: nil)]
        let spaghetti = spaghetti, caesar = caesar
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in [spaghetti, caesar] },
                                                                                 allergies: { _ in rows }))
        await store.load(members: [baby, gone])
        let target = night(meal: spaghetti, home: [baby.id: true, gone.id: true])
        let said = check(spaghetti, library: store.meals, allergies: store.allergies, on: target)
        #expect(said.texts == ["Contains milk (Baby)"])
        #expect(allergyTexts(card(target, store: store)) == said.texts)
    }

    @Test func planItNamesWhoeversHomeOnEachNight() {
        let library = [spaghetti, caesar]
        func said(_ home: [UUID: Bool]) -> AllergyCheck {
            PlanIt.allergyCheck(for: spaghetti, on: night(home: home), library: library, allergies: noraAllergies, lookup: .loaded)
        }
        #expect(said([nora.id: true]).texts == ["Contains milk (Nora)"])
        #expect(said([nora.id: false]) == AllergyCheck())
    }

    @Test func planItReadsTheLibrarysCopyNotTheOneItWasHanded() {
        var stale = spaghetti
        stale.sides = []
        let said = PlanIt.allergyCheck(for: stale, on: night(home: [nora.id: true]), library: [spaghetti, caesar],
                                       allergies: noraAllergies, lookup: .loaded)
        #expect(said.flags.count == 1, "a one-dish lookup is how a side's flags got lost before")
    }

    @Test func planItWaitsForTheLibraryThenSaysIfItCouldntRead() {
        func said(_ lookup: LibraryLookup) -> AllergyCheck {
            PlanIt.allergyCheck(for: spaghetti, on: night(home: [nora.id: true]), library: [], allergies: [], lookup: lookup)
        }
        #expect(said(.loading) == AllergyCheck(), "no false warning, and it's already got a dish it knows the name of")
        #expect(said(.failed).texts == [unknownNote], "it has the dish, but no sides and no allergies to check them against")
    }

    /// A reload is running, but the library it already has knows this dish.
    @Test func aReloadDoesntHideFlagsItCanStillRead() {
        let library = [spaghetti, caesar]
        let target = night(home: [nora.id: true])
        #expect(check(spaghetti, library: library, on: target, lookup: .loading).texts == ["Contains milk (Nora)"])
        #expect(PlanIt.allergyCheck(for: spaghetti, on: target, library: library, allergies: noraAllergies, lookup: .loading).texts
                == ["Contains milk (Nora)"])
    }

    @Test func aCatalogDishIsFlaggedForWhoeversHome() {
        let dish = CatalogDish.fixture(name: "Mac", ingredients: ["milk"])
        #expect(NightBadges.allergyCheck(catalog: dish, allergies: noraAllergies, home: [nora.id]).texts == ["Contains milk (Nora)"])
        #expect(NightBadges.allergyCheck(catalog: dish, allergies: noraAllergies, home: [owen.id]) == AllergyCheck())
        let empty = CatalogDish.fixture(name: "Mystery")
        #expect(NightBadges.allergyCheck(catalog: empty, allergies: noraAllergies, home: [nora.id]).note != nil)
        #expect(NightBadges.allergyCheck(catalog: empty, allergies: noraAllergies, home: [owen.id]) == AllergyCheck())
    }

    /// Someone added after the week was made has no row on its nights until a planner's phone fills them in. Nobody's said
    /// they're out, so their allergies count; only a row saying they're out takes them off.
    @Test func noAttendanceRowStillCountsForAllergies() async {
        let library = [spaghetti, caesar]
        let noRow = night(meal: spaghetti, home: [owen.id: true])
        let out = night(meal: spaghetti, home: [nora.id: false, owen.id: true])
        #expect(check(spaghetti, library: library, on: noRow).texts == ["Contains milk (Nora)"])
        #expect(check(spaghetti, library: library, on: out) == AllergyCheck())
        #expect(PlanIt.allergyCheck(for: spaghetti, on: noRow, library: library, allergies: noraAllergies, lookup: .loaded).texts
                == ["Contains milk (Nora)"])
        #expect(allergyTexts(card(noRow, library: library, allergies: noraAllergies, lookup: .loaded)) == ["Contains milk (Nora)"])
        #expect(allergyTexts(card(out, library: library, allergies: noraAllergies, lookup: .loaded)).isEmpty)
        let empty = night(meal: spaghetti)
        #expect(allergyTexts(card(empty, library: library, allergies: noraAllergies, lookup: .loaded)) == ["Contains milk (Nora)"],
                "a night with no rows at all")
    }

    @Test func noRowStillCountsOnAMissingDishAndAFreezerOffer() {
        let noRow = night(mealID: UUID(), home: [owen.id: true])
        #expect(card(noRow, allergies: noraAllergies, lookup: .loaded).badges == [.allergyUnchecked(unknownNote)])
        let open = night(home: [owen.id: true])
        let item = FreezerItem(id: UUID(), mealID: spaghetti.id, mealName: spaghetti.name, madeOn: sunday, state: .in)
        let offer = FreezerStash.offers([item], on: open, week: [open], library: [spaghetti, caesar], notForMe: [:], snoozed: [],
                                        allergies: noraAllergies, today: sunday).first
        #expect(offer?.flags.map(\.summary) == ["Contains milk (Nora)"])
    }

    @Test func noRowOnlyWidensAllergies() {
        let target = night(meal: spaghetti, home: [owen.id: true])
        #expect(target.home == [owen.id])
        #expect(target.allergyHome(noraAllergies) == [owen.id, nora.id])
        #expect(target.allergyHome([]) == [owen.id], "someone with no allergies isn't added")
        let model = WeekStore.planCard(for: target, nights: [target], members: [], library: [spaghetti, caesar],
                                       allergies: noraAllergies, settings: HouseholdSettings(), today: sunday, minuteNow: 0,
                                       notes: { _, home in home.contains(nora.id) ? ["Nora: on the side"] : [] }, lookup: .loaded)
        #expect(model.servingNotes.isEmpty, "a serving note is about who's actually at the table")
    }

    @Test func aRemovedMemberWithNoRowStaysOff() async {
        let gone = Member.fixture(firstName: "Gone", status: .removed)
        let dish = spaghetti, side = caesar
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in [dish, side] }, allergies: { _ in
            [AllergyRow(memberID: gone.id, allergen: .milk, customText: nil)]
        }))
        await store.load(members: [gone])
        #expect(allergyTexts(card(night(meal: dish, home: [owen.id: true]), store: store)).isEmpty)
    }

    @Test func theShoppingListCountsANoRowMemberToo() {
        func note(_ nights: [WeekNight]) -> String? {
            let layout = WeekLayout(nights: nights, today: sunday)
            return WeeklyList.build(nights: DoubleIt.listNights(layout, library: [spaghetti, caesar], allergies: noraAllergies), library: [spaghetti, caesar],
                                    allergies: noraAllergies).first { $0.name == "parmesan" }?.note
        }
        #expect(note([night(meal: spaghetti, home: [owen.id: true])])?.contains("Nora") == true)
        #expect(note([night(meal: spaghetti, home: [nora.id: false, owen.id: true])]) == nil)
        let monday = night(1, meal: spaghetti, home: [nora.id: false, owen.id: true])
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id, home: [owen.id: true])
        #expect(note([monday, tuesday])?.contains("Nora") == true, "the extra batch is for Tuesday's table too")
    }

    /// Flag, never filter: a flagged dish stays on offer everywhere it's offered.
    @Test func aFlaggedDishIsStillOffered() throws {
        let tonight = night(meal: nil, home: [nora.id: true])
        let layout = WeekLayout(nights: [tonight], today: sunday)
        #expect(PlanIt.choices(in: layout, for: spaghetti.id).map(\.id) == [tonight.id])
        let flagged = LibraryQuery.entries(meals: [spaghetti, caesar], library: [spaghetti, caesar], history: [],
                                           allergies: noraAllergies, favorites: [])
        #expect(LibraryQuery.apply(flagged, filter: nil, sort: .notLately, search: "spag").map(\.meal.id) == [spaghetti.id])
        let dish = spaghetti, side = caesar
        let item = FreezerItem(id: UUID(), mealID: dish.id, mealName: dish.name, madeOn: sunday, state: .in)
        let offer = try #require(FreezerStash.offers([item], on: tonight, week: [tonight], library: [dish, side], notForMe: [:],
                                                     snoozed: [], allergies: noraAllergies, today: sunday).first)
        #expect(offer.flags.count == 1)
    }
}
