import Foundation
import Synchronization
import Testing
@testable import Foon

@MainActor
struct DinnerStoreTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)
    /// Noon on the 3rd in New York, the household calendar's default.
    private let noon = DinnerPrompts.calendar(for: HouseholdSettings())
        .date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
    private let nightID = UUID()
    private let logID = UUID()
    private let chili = UUID()

    private func client(
        logs: @escaping @Sendable () -> [DinnerLog] = { [] },
        confirm: @escaping @Sendable (UUID) async throws -> UUID = { _ in UUID() },
        react: @escaping @Sendable (UUID, UUID, ReactionKind) async throws -> UUID = { _, _, _ in UUID() },
        correct: @escaping @Sendable (UUID, DinnerCorrection) async throws -> Void = { _, _ in },
        nights: @escaping @Sendable (CalendarDay, CalendarDay) -> [WeekNight] = { _, _ in [] },
        setNotHome: @escaping @Sendable (UUID, UUID) async throws -> Void = { _, _ in }
    ) -> DinnerClient {
        DinnerClient(logs: { _, _ in logs() }, confirm: confirm, react: react, correct: correct,
                     nights: { _, from, through in nights(from, through) }, setNotHome: setNotHome)
    }

    @Test func loadsLastNightAndTonightWhateverWeekTheyreIn() async {
        let asked = Mutex<(CalendarDay, CalendarDay)?>(nil)
        let store = DinnerStore(householdID: UUID(), client: client(nights: { from, through in
            asked.withLock { $0 = (from, through) }
            return []
        }), now: { self.noon })
        await store.load(settings: HouseholdSettings())
        #expect(asked.withLock { $0 }?.0 == today.adding(days: -1))
        #expect(asked.withLock { $0 }?.1 == today)
    }

    @Test func aReactionSavesThenReloads() async {
        let reacted = Mutex<[ReactionKind]>([])
        let loads = Mutex(0)
        let store = DinnerStore(householdID: UUID(), client: client(
            logs: { loads.withLock { $0 += 1 }; return [] },
            react: { _, _, kind in reacted.withLock { $0.append(kind) }; return UUID() }
        ), now: { self.noon })
        #expect(await store.react(nightID: nightID, memberID: UUID(), .favorite))
        #expect(reacted.withLock { $0 } == [.favorite])
        #expect(loads.withLock { $0 } == 1, "reloaded, so the card goes away")
    }

    @Test func weHadSomethingElseConfirmsThenChangesOnlyTheDish() async {
        let corrections = Mutex<[(UUID, DinnerCorrection)]>([])
        let store = DinnerStore(householdID: UUID(), client: client(
            confirm: { _ in self.logID },
            correct: { id, correction in corrections.withLock { $0.append((id, correction)) } }
        ), now: { self.noon })
        #expect(await store.hadInstead(nightID: nightID, .quickPick(.takeout)), "no log yet: confirmed first")
        let sent = corrections.withLock { $0 }
        #expect(sent.first?.0 == logID)
        #expect(sent.first?.1 == .dish(mealID: nil, quickPick: .takeout), "leftovers and the cook aren't touched")
    }

    @Test func theDishOnlyChangesBeforeAnyoneRates() async {
        let rated = DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil,
                              reactions: [Reaction(memberID: UUID(), kind: .good, offTonight: false, comment: nil,
                                                   createdAt: .now)])
        let store = DinnerStore(householdID: UUID(), client: client(logs: { [rated] }), now: { self.noon })
        #expect(store.canChangeDish(nightID: nightID), "nothing loaded yet")
        await store.load(settings: HouseholdSettings())
        #expect(!store.canChangeDish(nightID: nightID))
    }

    @Test func extrasSaveLeftoversAndTheCookOnly() async {
        let corrections = Mutex<[DinnerCorrection]>([])
        let cook = UUID()
        let log = DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil)
        let store = DinnerStore(householdID: UUID(), client: client(
            logs: { [log] }, correct: { _, correction in corrections.withLock { $0.append(correction) } }
        ), now: { self.noon })
        await store.load(settings: HouseholdSettings())
        #expect(await store.saveExtras(nightID: nightID, leftovers: false, cookedBy: cook))
        #expect(corrections.withLock { $0 } == [.extras(leftovers: false, cookedByMemberID: cook)])
    }

    @Test func todayIsTheHouseholdsNotThePhones() async {
        // 11pm in Los Angeles on the 2nd is already the 3rd in New York.
        var settings = HouseholdSettings()
        settings.timeZone = "America/Los_Angeles"
        let lateInLA = DinnerPrompts.calendar(for: settings)
            .date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23))!
        let asked = Mutex<CalendarDay?>(nil)
        let store = DinnerStore(householdID: UUID(), client: client(nights: { _, through in
            asked.withLock { $0 = through }
            return []
        }), now: { lateInLA })
        await store.load(settings: settings)
        #expect(asked.withLock { $0 } == CalendarDay(year: 2026, month: 11, day: 2))
        #expect(store.today == CalendarDay(year: 2026, month: 11, day: 2))
    }

    @Test func anOlderLoadFinishingLastIsIgnored() async {
        let first = Mutex(true)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let log = DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil)
        let store = DinnerStore(householdID: UUID(), client: DinnerClient(
            logs: { _, _ in
                if first.withLock({ let was = $0; $0 = false; return was }) {
                    for await _ in gate { break }  // the first load stalls until the second is done
                    return []
                }
                return [log]
            },
            confirm: { _ in UUID() }, react: { _, _, _ in UUID() }, correct: { _, _ in },
            nights: { _, _, _ in [] }, setNotHome: { _, _ in }
        ), now: { self.noon })
        let slow = Task { await store.load(settings: HouseholdSettings()) }
        await Task.yield()
        await store.load(settings: HouseholdSettings())
        release.yield()
        await slow.value
        #expect(store.logs == [log], "the newer load's answer stands")
    }

    @Test func aFailedWriteSaysSo() async {
        let store = DinnerStore(householdID: UUID(), client: client(setNotHome: { _, _ in
            throw URLError(.notConnectedToInternet)
        }), now: { self.noon })
        #expect(!(await store.notHome(nightID: nightID, memberID: UUID())))
        #expect(store.errorMessage != nil)
        #expect(store.saving.isEmpty)
    }
}
