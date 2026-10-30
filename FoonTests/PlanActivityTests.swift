import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
private let ann = Member.fixture(firstName: "Ann", role: .planner)
private let ben = Member.fixture(firstName: "Ben", role: .planner)
private let gone = Member.fixture(firstName: "Gus", status: .removed)
private let family = [ann, ben, gone]
private let tacos = PlanChange.Held(mealID: UUID(), mealName: "Tacos")
private let chili = PlanChange.Held(mealID: UUID(), mealName: "Chili")
private let empty = PlanChange.Held()
private let gmt: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let moment = Date(timeIntervalSince1970: 2_000_000_000)

private func change(_ id: Int64 = 1, kind: PlanChange.Kind? = .pick, night: UUID = UUID(), on date: CalendarDay = sunday.adding(days: 2),
                    actor: UUID? = ann.id, linked: CalendarDay? = nil, before: PlanChange.Held = chili,
                    after: PlanChange.Held = tacos, afterLocked: Bool = true, restorable: Bool = true,
                    at: Date = moment) -> PlanChange {
    PlanChange(id: id, nightID: night, nightDate: date, actorID: actor, kind: kind, linkedDate: linked, before: before,
               after: after, afterLocked: afterLocked, restorable: restorable, createdAt: at)
}

private func line(_ change: PlanChange, members: [Member] = family) -> String {
    PlanChangeText.line(change, members: members, today: sunday, calendar: gmt)
}

struct PlanActivityEntryTests {
    @Test func aWholeBuildIsOneEntryWithACountThatsTrue() {
        let entries = PlanActivity.entries([change(3), change(2), change(1)])
        #expect(entries.count == 1)
        #expect(PlanChangeText.line(entries[0], members: family, today: sunday, calendar: gmt) == "Ann planned 3 nights")
    }

    @Test func separateWritesStaySeparate() {
        let entries = PlanActivity.entries([change(2, at: moment.addingTimeInterval(1)), change(1)])
        #expect(entries.count == 2)
    }

    @Test func twoPeopleAtTheSameInstantArentOneEntry() {
        #expect(PlanActivity.entries([change(2, actor: ben.id), change(1)]).count == 2)
    }

    @Test func whatTheSystemMovedStaysItsOwnEntryInTheMiddleOfABuild() {
        let follow = change(2, kind: .follow, actor: nil, linked: sunday, after: empty)
        let entries = PlanActivity.entries([change(3), follow, change(1)])
        #expect(entries.count == 2)
        #expect(entries[0].changes.map(\.id) == [3, 1])
        #expect(entries[1].changes == [follow])
    }

    @Test func aKindThisBuildDoesntKnowShowsNothing() {
        let unknown = change(2, kind: nil)
        #expect(PlanActivity.entries([unknown]).isEmpty)
        #expect(PlanActivity.changes(on: unknown.nightID, in: [unknown]).isEmpty)
    }

    @Test func aBuildCutShortByTheFetchLimitIsntCountedAsPartOfItself() {
        let older = moment.addingTimeInterval(-60)
        let rows = [change(3), change(2, at: older), change(1, at: older)]
        let entries = PlanActivity.entries(rows, limit: 3)
        #expect(entries.map(\.id) == [3], "the last statement may have more nights than were read")
        #expect(PlanActivity.entries(rows, limit: 4).count == 2, "short of the limit, it's all there")
    }
}

struct PlanChangeTextTests {
    @Test func aSwapSaysWhoAndWhat() {
        #expect(line(change()) == "Ann swapped Tuesday to Tacos")
    }

    @Test func aQuickPickReadsAsItsLabel() {
        #expect(line(change(after: .init(quickPick: .takeout))) == "Ann swapped Tuesday to Takeout")
    }

    @Test func anEmptyNightGettingADishIsPlanningItNotSwappingIt() {
        #expect(line(change(before: empty)) == "Ann planned Tacos on Tuesday")
    }

    @Test func clearingANightSaysSo() {
        #expect(line(change(after: empty)) == "Ann cleared Tuesday")
    }

    @Test func awayDatesAreFoonsDoingAndNoOneElses() {
        // Even if a row somehow had someone's name on it: the kind says who.
        #expect(line(change(kind: .away, actor: ann.id, after: empty)) == "Foon cleared Tuesday for away dates")
        #expect(line(change(kind: .away, actor: nil, after: empty)) == "Foon cleared Tuesday for away dates")
    }

    @Test func aLeftoversNightGoingBackIsFoonsDoing() {
        let monday = sunday.adding(days: 1)
        #expect(line(change(kind: .follow, actor: nil, linked: monday)) == "Foon put Tuesday back to Tacos when Monday's dinner changed")
        #expect(line(change(kind: .follow, actor: nil, linked: monday, after: empty)) == "Foon cleared Tuesday when Monday's dinner changed")
    }

    @Test func doublingNamesBothNights() {
        #expect(line(change(kind: .doubled, linked: sunday.adding(days: 1), after: .init(quickPick: .leftovers)))
            == "Ann doubled Monday's dinner, with leftovers on Tuesday")
    }

    @Test func theFreezerAndBothUndosSaySo() {
        #expect(line(change(kind: .freezer)) == "Ann put Tacos from the freezer on Tuesday")
        #expect(line(change(kind: .undoDouble)) == "Ann undid Double it on Tuesday")
        #expect(line(change(kind: .undo)) == "Ann undid the last change to Tuesday, back to Tacos")
        #expect(line(change(kind: .undo, after: empty)) == "Ann undid the last change to Tuesday, so it's empty again")
    }

    @Test func aRemovedMemberReadsAsAFormerMember() {
        #expect(line(change(actor: gone.id)) == "Former member swapped Tuesday to Tacos")
    }

    @Test func noProfileBehindTheWriteNamesNobody() {
        #expect(line(change(actor: nil)) == "Someone swapped Tuesday to Tacos")
    }

    @Test func aFamilyThatHasntLoadedIsntAFormerMember() {
        #expect(line(change(), members: []) == "Someone swapped Tuesday to Tacos")
    }

    @Test func aDayOutsideTheWeekAheadCarriesItsDate() {
        let lastTuesday = sunday.adding(days: -5)
        #expect(PlanChangeText.day(lastTuesday, today: sunday, calendar: gmt) == "Tuesday, Oct 27")
        #expect(PlanChangeText.day(sunday.adding(days: 6), today: sunday, calendar: gmt) == "Saturday")
        #expect(PlanChangeText.day(sunday.adding(days: 7), today: sunday, calendar: gmt) == "Sunday, Nov 8")
    }

    @Test func theDayFollowsTheHouseholdsCalendarNotTheDevices() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var pagoPago = Calendar(identifier: .gregorian)
        pagoPago.timeZone = try #require(TimeZone(identifier: "Pacific/Pago_Pago"))
        #expect(PlanChangeText.day(sunday, today: sunday, calendar: tokyo) == "Sunday")
        #expect(PlanChangeText.day(sunday, today: sunday, calendar: pagoPago) == "Sunday")
    }

    @Test func theUndoButtonSaysWhatComesBack() {
        #expect(PlanChangeText.undoTitle(change()) == "Undo: back to Chili")
        #expect(PlanChangeText.undoTitle(change(before: .init(quickPick: .takeout))) == "Undo: back to Takeout")
        #expect(PlanChangeText.undoTitle(change(before: empty)) == "Undo: leave it empty")
    }
}

struct PlanActivityCanUndoTests {
    private func tuesday(meal: UUID? = tacos.mealID, pick: QuickPick? = nil, locked: Bool = true, leftoversFrom: UUID? = nil,
                         stash: UUID? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: sunday.adding(days: 2), effort: .normal, mealID: meal, quickPick: pick, locked: locked,
                  attendance: [:], leftoversFrom: leftoversFrom, stashItemID: stash)
    }

    private func can(_ entry: PlanChange? = nil, night: WeekNight, nights: [WeekNight] = [], logged: Bool = false,
                     away: [AwayDates] = [], today: CalendarDay = sunday, last: PlanChange? = nil) -> Bool {
        let entry = entry ?? change(night: night.id)
        return PlanActivity.canUndo(entry, last: last ?? entry, on: night, nights: nights, isLogged: logged, away: away, today: today)
    }

    @Test func aPlainChangeStillTheLastAndStillThereCanBeUndone() {
        #expect(can(night: tuesday()))
    }

    @Test func notIfANewerChangeCameAfter() {
        #expect(!can(night: tuesday(), last: change(2)))
    }

    @Test func notIfTheNightHoldsSomethingElseNow() {
        #expect(!can(night: tuesday(meal: chili.mealID)))
        #expect(!can(night: tuesday(meal: nil, pick: .takeout)))
        #expect(!can(night: tuesday(locked: false)), "someone changed the lock since")
    }

    @Test func notIfTheServerSaidItCantBeRestored() {
        let night = tuesday()
        #expect(!can(change(night: night.id, restorable: false), night: night))
    }

    @Test(arguments: [PlanChange.Kind.doubled, .undoDouble, .freezer, .away, .follow, .undo])
    func onlyAPlainChange(kind: PlanChange.Kind) {
        let night = tuesday()
        #expect(!can(change(kind: kind, night: night.id), night: night))
    }

    @Test func notOnAPastNightInTheHouseholdsDay() {
        #expect(!can(night: tuesday(), today: sunday.adding(days: 3)))
        #expect(can(night: tuesday(), today: sunday.adding(days: 2)), "tonight still can")
    }

    @Test func notOnALoggedDinner() {
        #expect(!can(night: tuesday(), logged: true))
    }

    @Test func notOnAnAwayNight() {
        let away = AwayDates(from: sunday.adding(days: 1), to: sunday.adding(days: 3))
        #expect(!can(night: tuesday(), away: [away]))
    }

    @Test func notOnEitherEndOfALink() {
        #expect(!can(night: tuesday(leftoversFrom: UUID())))
        #expect(!can(night: tuesday(stash: UUID())))
        let dish = tuesday()
        let later = tuesday(meal: nil, pick: .leftovers, leftoversFrom: dish.id)
        #expect(!can(night: dish, nights: [dish, later]))
        #expect(can(night: dish, nights: [dish, tuesday(meal: nil)]), "a night with no link to it doesn't matter")
    }
}

@MainActor
struct PlanActivityStoreTests {
    @Test func anOlderLoadFinishingLastIsIgnored() async {
        let (parked, parkedSignal) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        var client = WeekClient.fake()
        client.planChanges = { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            guard call == 1 else { return [change(2)] }
            parkedSignal.yield()
            for await _ in gate { break }
            return [change(1)]
        }
        let store = PlanActivityStore(householdID: UUID(), client: client)
        let slow = Task { await store.load() }
        for await _ in parked { break }
        await store.load()
        #expect(store.changes.map(\.id) == [2])
        open.yield()
        await slow.value
        open.finish()
        parkedSignal.finish()
        #expect(store.changes.map(\.id) == [2], "the newer read stands")
    }

    @Test func aFailedLoadKeepsWhatItHadAndSays() async {
        let fail = Mutex(false)
        var client = WeekClient.fake()
        client.planChanges = { _ in
            if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return [change()]
        }
        let store = PlanActivityStore(householdID: UUID(), client: client)
        await store.load()
        fail.withLock { $0 = true }
        await store.load()
        #expect(store.changes.count == 1)
        #expect(store.errorMessage?.contains("connection") == true)
    }

    @Test func aCancelledLoadIsntAFailure() async {
        var client = WeekClient.fake()
        client.planChanges = { _ in throw URLError(.cancelled) }
        let store = PlanActivityStore(householdID: UUID(), client: client)
        await store.load()
        #expect(store.errorMessage == nil)
    }

    @Test func aNightsChangesAreItsOwn() async {
        let night = UUID()
        var client = WeekClient.fake()
        client.planChanges = { _ in [change(2, night: night), change(1)] }
        let store = PlanActivityStore(householdID: UUID(), client: client)
        await store.load()
        #expect(store.changes(on: night).map(\.id) == [2])
    }
}

private let undoNight = UUID()

private func undoWeek(_ meal: UUID?) -> Week {
    Week(planID: UUID(), start: sunday, nights: [
        WeekNight(id: undoNight, date: sunday.adding(days: 2), effort: .normal, mealID: meal, locked: false, attendance: [:])
    ])
}

@MainActor
struct WeekStoreUndoTests {
    /// The server's night holds Tacos until an undo goes through, then Chili.
    private func store(undo: @escaping @Sendable (Int64) async throws -> Void) -> WeekStore {
        let holding = Mutex<UUID?>(tacos.mealID)
        var client = WeekClient.fake(week: { _, _ in undoWeek(holding.withLock { $0 }) })
        client.undoPlanChange = { id in
            try await undo(id)
            holding.withLock { $0 = chili.mealID }
        }
        return WeekStore(householdID: UUID(), client: client, today: { sunday })
    }

    @Test func undoAsksTheServerThenShowsWhatItRead() async {
        let asked = Mutex<[Int64]>([])
        let store = store(undo: { id in asked.withLock { $0.append(id) } })
        await store.load(settings: HouseholdSettings())
        #expect(await store.undoChange(change(7, night: undoNight)))
        #expect(asked.withLock { $0 } == [7])
        #expect(store.week?.nights[0].mealID == chili.mealID)
        #expect(store.errorMessage == nil)
    }

    @Test func aNightThatMovedOnAnotherPhoneGetsItsOwnWordsAndTheLatest() async {
        let store = store(undo: { _ in throw PostgrestError(code: "FD012", message: "moved") })
        await store.load(settings: HouseholdSettings())
        #expect(await !store.undoChange(change(night: undoNight)))
        #expect(store.errorMessage?.contains("changed since") == true)
        #expect(store.errorMessage?.contains("connection") == false)
    }

    @Test func aChangeThatCantBeUndonePointsAtSwap() async {
        let store = store(undo: { _ in throw PostgrestError(code: "FD013", message: "no") })
        await store.load(settings: HouseholdSettings())
        #expect(await !store.undoChange(change(night: undoNight)))
        #expect(store.errorMessage == "Can't undo that one. Swap it instead.")
    }

    @Test func aNonPlannerSeesWhySheCantAndAnAwayNightSaysSo() async {
        let code = Mutex("42501")
        let store = store(undo: { _ in throw PostgrestError(code: code.withLock { $0 }, message: "no") })
        await store.load(settings: HouseholdSettings())
        #expect(await !store.undoChange(change(night: undoNight)))
        #expect(store.errorMessage == "Only planners can change the plan.")
        code.withLock { $0 = "22023" }
        #expect(await !store.undoChange(change(night: undoNight)))
        #expect(store.errorMessage?.contains("away") == true)
        #expect(store.awayRefusals == 1, "so the household reloads and the device learns the dates")
    }

    @Test func noConnectionSaysConnection() async {
        let store = store(undo: { _ in throw URLError(.notConnectedToInternet) })
        await store.load(settings: HouseholdSettings())
        #expect(await !store.undoChange(change(night: undoNight)))
        #expect(store.errorMessage?.contains("connection") == true)
    }

    @Test func aNightThisDeviceIsntShowingIsLeftAlone() async {
        let asked = Mutex(0)
        let store = store(undo: { _ in asked.withLock { $0 += 1 } })
        await store.load(settings: HouseholdSettings())
        #expect(await !store.undoChange(change()))
        #expect(asked.withLock { $0 } == 0)
    }

    /// What NightDetailView does after a saved undo: a request that landed on the dish goes back to open.
    @Test func aRequestOnTheUndoneDishFollowsThroughIdeasSync() async throws {
        let request = DinnerRequest(requestedByMemberID: ann.id, mealID: tacos.mealID, status: .planned, plannedNightID: undoNight,
                                    plannedDate: sunday.adding(days: 2))
        let updates = Mutex<[(UUID, RequestUpdate)]>([])
        let ideas = IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in [request] }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true },
            update: { id, update in updates.withLock { $0.append((id, update)) } }
        ))
        await ideas.load()
        let store = store(undo: { _ in })
        await store.load(settings: HouseholdSettings())
        #expect(await store.undoChange(change(night: undoNight)))
        await ideas.sync(with: store.week, today: store.todayDay, requestNights: store.requestNights, away: store.awayDates)
        let sent = updates.withLock { $0 }
        #expect(sent.first?.0 == request.id)
        #expect(sent.first?.1.status == .open)
    }
}
