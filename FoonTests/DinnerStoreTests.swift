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

    private final class Flag: Sendable {
        let value = Mutex(false)
    }

    private func tonightsChili(me: UUID, rated: Flag) -> @Sendable () -> [DinnerLog] {
        { [logID, nightID, today, chili] in
            let reactions = rated.value.withLock { $0 } ? [Reaction(memberID: me, kind: .good, offTonight: false, createdAt: .now)] : []
            return [DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil,
                              reactions: reactions)]
        }
    }

    private func night() -> WeekNight {
        WeekNight(id: nightID, date: today, effort: .normal, dinnerTime: "18:00", mealID: chili, mealName: "Chili",
                  quickPick: nil, locked: false, attendance: [:])
    }

    @Test func rightAfterRatingTheCardOffersAComment() async {
        let me = UUID()
        let rated = Flag()
        let tonight = night()
        let store = DinnerStore(householdID: UUID(), client: client(
            logs: tonightsChili(me: me, rated: rated),
            react: { _, _, _ in rated.value.withLock { $0 = true }; return UUID() },
            nights: { _, _ in [tonight] }
        ), now: { self.noon })
        await store.load(settings: HouseholdSettings())
        #expect(store.commentPrompts(me: me).isEmpty, "nothing's offered before rating")

        await store.rate(nightID: nightID, memberID: me, .good)
        #expect(store.commentPrompts(me: me).map(\.id) == [nightID])
        #expect(store.commentPrompts(me: UUID()).isEmpty, "only to who rated")

        store.skipComment(nightID: nightID)
        #expect(store.commentPrompts(me: me).isEmpty, "Not now means it's gone")
    }

    @Test func passingThePhoneDoesntOfferAComment() async {
        let me = UUID()
        let rated = Flag()
        let tonight = night()
        let store = DinnerStore(householdID: UUID(), client: client(
            logs: tonightsChili(me: me, rated: rated),
            react: { _, _, _ in rated.value.withLock { $0 = true }; return UUID() },
            nights: { _, _ in [tonight] }
        ), now: { self.noon })
        await store.load(settings: HouseholdSettings())
        await store.react(nightID: nightID, memberID: me, .good)
        #expect(store.commentPrompts(me: me).isEmpty)
    }

    @Test func aFailedRatingOffersNoComment() async {
        struct Offline: Error {}
        let me = UUID()
        let tonight = night()
        // Their rating from earlier is already on the log: only the failed tap can keep the card away.
        let rated = Flag()
        rated.value.withLock { $0 = true }
        let store = DinnerStore(householdID: UUID(), client: client(
            logs: tonightsChili(me: me, rated: rated),
            react: { _, _, _ in throw Offline() },
            nights: { _, _ in [tonight] }
        ), now: { self.noon })
        await store.load(settings: HouseholdSettings())
        await store.rate(nightID: nightID, memberID: me, .good)
        #expect(store.commentPrompts(me: me).isEmpty)
    }

    @Test func savingACommentSendsTheTidiedWordsAndClosesTheCard() async {
        let me = UUID()
        let rated = Flag()
        let sent = Mutex<[String]>([])
        let tonight = night()
        var fake = client(
            logs: tonightsChili(me: me, rated: rated),
            react: { _, _, _ in rated.value.withLock { $0 = true }; return UUID() },
            nights: { _, _ in [tonight] }
        )
        fake.comment = { [logID] log, member, text in
            #expect(log == logID)
            #expect(member == me)
            sent.withLock { $0.append(text) }
        }
        let store = DinnerStore(householdID: UUID(), client: fake, now: { self.noon })
        await store.load(settings: HouseholdSettings())
        await store.rate(nightID: nightID, memberID: me, .good)

        #expect(await store.saveComment(nightID: nightID, memberID: me, typed: "   \n ") == false, "blank saves nothing")
        #expect(sent.withLock { $0 }.isEmpty)
        #expect(store.commentPrompts(me: me).count == 1, "and doesn't close the card")

        #expect(await store.saveComment(nightID: nightID, memberID: me, typed: "  Too spicy\nfor me "))
        #expect(sent.withLock { $0 } == ["Too spicy for me"])
        #expect(store.commentPrompts(me: me).isEmpty)
    }

    @Test func aCommentThatDoesntSaveKeepsTheCardOpen() async {
        struct Offline: Error {}
        let me = UUID()
        let rated = Flag()
        let tonight = night()
        var fake = client(
            logs: tonightsChili(me: me, rated: rated),
            react: { _, _, _ in rated.value.withLock { $0 = true }; return UUID() },
            nights: { _, _ in [tonight] }
        )
        fake.comment = { _, _, _ in throw Offline() }
        let store = DinnerStore(householdID: UUID(), client: fake, now: { self.noon })
        await store.load(settings: HouseholdSettings())
        await store.rate(nightID: nightID, memberID: me, .good)
        #expect(await store.saveComment(nightID: nightID, memberID: me, typed: "Good") == false)
        #expect(store.errorMessage != nil)
        #expect(store.commentPrompts(me: me).count == 1)

        store.skipComment(nightID: nightID)
        #expect(store.errorMessage == nil, "Not now doesn't leave the failure on screen")
    }

    @Test func aCommentFitsWhatTheServerAccepts() throws {
        #expect(DinnerPrompts.comment(from: "") == nil)
        #expect(DinnerPrompts.comment(from: " \n\t ") == nil)
        #expect(DinnerPrompts.comment(from: "  Line one\n\nline two ") == "Line one line two")

        let long = try #require(DinnerPrompts.comment(from: String(repeating: "x", count: 200)))
        #expect(long.unicodeScalars.count == 140)

        // A family emoji is one character to a person and seven to the server. It's kept whole or left out.
        let family = "👨‍👩‍👧‍👦"
        let emoji = try #require(DinnerPrompts.comment(from: String(repeating: family, count: 30)))
        #expect(emoji.unicodeScalars.count <= 140)
        #expect(emoji.count == 140 / family.unicodeScalars.count)

        let cutAtASpace = try #require(DinnerPrompts.comment(from: String(repeating: "x", count: 139) + " y"))
        #expect(cutAtASpace == String(repeating: "x", count: 139), "no space left on the end")
        #expect(DinnerPrompts.capped("Short") == "Short")
    }

    @Test func theDishOnlyChangesBeforeAnyoneRates() async {
        let rated = DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil,
                              reactions: [Reaction(memberID: UUID(), kind: .good, offTonight: false,
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
        let (parked, parkedSignal) = AsyncStream<Void>.makeStream()
        let log = DinnerLog(id: logID, nightID: nightID, date: today, mealID: chili, mealName: "Chili", quickPick: nil)
        var client = DinnerClient.preview
        client.logs = { _, _ in
            if first.withLock({ let was = $0; $0 = false; return was }) {
                parkedSignal.yield()
                for await _ in gate { break }  // the first load stalls until the second is done
                return []
            }
            return [log]
        }
        let store = DinnerStore(householdID: UUID(), client: client, now: { self.noon })
        let slow = Task { await store.load(settings: HouseholdSettings()) }
        // Only start the second load once the first is parked at the gate, so the two can't swap places.
        for await _ in parked { break }
        await store.load(settings: HouseholdSettings())
        release.yield()
        release.finish()
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
