import Foundation
import Supabase
import Testing
@testable import Foon

@MainActor
struct StoreRunTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func run(startedBy: UUID? = nil) -> StoreRun {
        StoreRun(id: UUID(), startedBy: startedBy, startedAt: start, endsAt: start.addingTimeInterval(600))
    }

    private func entry(createdAt: Date?, folded: [ListEntry] = []) -> ListEntry {
        ListEntry(lineID: UUID(), itemID: UUID(), name: "Milk", list: .quick, urgency: .whenever, quantity: nil, lineNote: nil,
                  itemNote: nil, category: .dairyEggs, checkedAt: nil, keepOnHand: false, folded: folded, createdAt: createdAt)
    }

    // MARK: - The run

    @Test func aRunIsOpenForTenMinutesAndCountsDownInWholeMinutes() {
        let run = run()
        #expect(run.isOpen(at: start.addingTimeInterval(599)))
        #expect(!run.isOpen(at: start.addingTimeInterval(600)))
        #expect(run.minutesLeft(at: start) == 10)
        #expect(run.minutesLeft(at: start.addingTimeInterval(61)) == 9, "8 min 59 s reads as 9")
        #expect(run.minutesLeft(at: start.addingTimeInterval(590)) == 1, "the last seconds still read 1")
        #expect(run.minutesLeft(at: start.addingTimeInterval(700)) == 0)
    }

    @Test func onlyAnAdultStartsOne() {
        #expect(StoreRun.canStart(.fixture(ageGroup: .adult)))
        #expect(!StoreRun.canStart(.fixture(ageGroup: .kid)))
        #expect(!StoreRun.canStart(.fixture(ageGroup: .adult, status: .removed)))
        #expect(!StoreRun.canStart(nil))
    }

    // MARK: - Just added

    @Test func linesAddedDuringTheRunAreJustAdded() {
        let run = run()
        let now = start.addingTimeInterval(900)
        #expect(entry(createdAt: start.addingTimeInterval(120)).justAdded(during: run, now: now))
        #expect(!entry(createdAt: start.addingTimeInterval(-1)).justAdded(during: run, now: now), "already on the list")
        #expect(!entry(createdAt: start.addingTimeInterval(601)).justAdded(during: run, now: now), "after it ended")
        #expect(!entry(createdAt: nil).justAdded(during: run, now: now), "an old cache with no time isn't guessed at")
        #expect(!entry(createdAt: start.addingTimeInterval(120)).justAdded(during: nil, now: now))
    }

    @Test func aRowIsJustAddedWhenItsOtherLineWentOnDuringTheRun() {
        let weekly = entry(createdAt: start.addingTimeInterval(-86_400))
        let quick = entry(createdAt: start.addingTimeInterval(60))
        #expect(entry(createdAt: start.addingTimeInterval(-86_400), folded: [quick]).justAdded(during: run(),
                                                                                               now: start.addingTimeInterval(60)))
        #expect(!entry(createdAt: start.addingTimeInterval(-86_400), folded: [weekly]).justAdded(during: run(),
                                                                                                 now: start.addingTimeInterval(60)))
    }

    @Test func anOldRunMarksNothing() {
        let line = entry(createdAt: start.addingTimeInterval(60))
        #expect(line.justAdded(during: run(), now: start.addingTimeInterval(2 * 3600 - 1)))
        #expect(!line.justAdded(during: run(), now: start.addingTimeInterval(2 * 3600)), "the next trip isn't this one")
    }

    @Test func entriesCarryWhenTheirLineWentOn() throws {
        let line = CachedListItem(id: UUID(), householdID: UUID(), itemID: UUID(), itemName: "Milk", list: .quick,
                                  urgency: .whenever, source: .manual, note: nil, checkedAt: nil, createdAt: start)
        #expect(ListEntry.entries(lines: [line], items: []).first?.createdAt == start)
    }

    @Test func aPulledLineKeepsTheServersTime() throws {
        let json = Data("""
        {"id": "\(UUID())", "household_id": "\(UUID())", "item_id": "\(UUID())", "list": "quick", "urgency": "whenever",
         "source": "manual", "note": null, "checked_at": null, "created_at": "2026-11-02T18:30:00Z"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(ListItemRow.self, from: json)
        #expect(row.createdAt == ISO8601DateFormatter().date(from: "2026-11-02T18:30:00Z"))
    }

    @Test func theListRefreshesEveryHalfMinuteAndExactlyWhenTheRunEnds() {
        let entries = StoreRunSchedule(endsAt: start.addingTimeInterval(45)).entries(from: start, mode: .normal)
        #expect(Array(entries.prefix(4)) == [start, start.addingTimeInterval(30), start.addingTimeInterval(45),
                                             start.addingTimeInterval(75)])
        let idle = StoreRunSchedule(endsAt: nil).entries(from: start, mode: .normal)
        #expect(Array(idle.prefix(2)) == [start, start.addingTimeInterval(30)])
    }

    // MARK: - Words

    @Test func theListSaysWhoIsShoppingAndHowLongIsLeft() {
        let ben = Member.fixture(firstName: "Ben")
        let ana = Member.fixture(firstName: "Ana")
        let now = start.addingTimeInterval(120)
        #expect(StoreRunText.running(run(startedBy: ben.id), members: [ben, ana], me: ana, now: now)
            == "Ben's at the store: 8 min left")
        #expect(StoreRunText.running(run(startedBy: ana.id), members: [ben, ana], me: ana, now: now)
            == "You're at the store: 8 min left")
        #expect(StoreRunText.running(run(startedBy: ben.id), members: [ben], me: ana, now: start.addingTimeInterval(590))
            == "Ben's at the store: 1 min left")
        #expect(StoreRunText.running(run(startedBy: nil), members: [ben], me: ana, now: now) == "Store run: 8 min left")
    }

    // MARK: - Store

    @Test func startingShowsTheRunTheServerHandsBack() async {
        let open = run(startedBy: UUID())
        let store = StoreRunStore(householdID: UUID(), client: StoreRunClient(latest: { _ in nil }, start: { _ in open }))
        await store.start()
        #expect(store.run == open)
        #expect(store.openRun(at: start.addingTimeInterval(60)) == open)
        #expect(store.openRun(at: start.addingTimeInterval(601)) == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func aKidStartingIsTurnedAwayInWords() async {
        let store = StoreRunStore(householdID: UUID(), client: StoreRunClient(
            latest: { _ in nil }, start: { _ in throw PostgrestError(code: "42501", message: "an adult heads to the store") }))
        await store.start()
        #expect(store.run == nil)
        #expect(store.errorMessage == "Only an adult in the family can say they're heading to the store.")
        #expect(!store.isStarting)
    }

    @Test func loadingFindsAnOpenRunAndKeepsItWhenOffline() async {
        let open = run()
        let store = StoreRunStore(householdID: UUID(), client: StoreRunClient(latest: { _ in open }, start: { _ in open }))
        await store.load()
        #expect(store.run == open)
        let offline = StoreRunStore(householdID: UUID(), client: StoreRunClient(
            latest: { _ in throw URLError(.notConnectedToInternet) }, start: { _ in open }), run: open)
        await offline.load()
        #expect(offline.run == open)
    }
}
