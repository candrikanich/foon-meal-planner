import Foundation
import SwiftData
import Testing
@testable import Foon

/// What Siri says for "What's for dinner?" (#62): the widget's snapshot, tonight on the household's clock.
@Suite struct TonightAnswerTests {
    private let zone = "America/Chicago"
    private let today = CalendarDay(year: 2026, month: 11, day: 4)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func at(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func snapshot(_ nights: [TonightSnapshot.Night]) -> TonightSnapshot {
        TonightSnapshot(householdID: UUID(), timeZone: zone, nights: nights)
    }

    @Test func aDishWithItsTime() throws {
        let night = TonightSnapshot.Night(date: today, title: "Tacos", isDish: true, dinnerTime: "18:30")
        let time = try #require(night.dinnerTimeText)
        #expect(TonightAnswer.text(snapshot([night]), now: at(day: 4, hour: 12)) == "Tonight: Tacos, at \(time).")
    }

    @Test func aQuickPickWithoutATime() {
        let night = TonightSnapshot.Night(date: today, title: "Takeout")
        #expect(TonightAnswer.text(snapshot([night]), now: at(day: 4, hour: 12)) == "Tonight: Takeout.")
    }

    @Test func awayAndNothingPlanned() {
        let away = snapshot([.init(date: today, isAway: true)])
        #expect(TonightAnswer.text(away, now: at(day: 4, hour: 12)) == "You're away tonight.")
        let empty = snapshot([.init(date: today, dinnerTime: "18:30")])
        #expect(TonightAnswer.text(empty, now: at(day: 4, hour: 12)) == "Nothing's planned for tonight yet.")
        #expect(TonightAnswer.text(snapshot([]), now: at(day: 4, hour: 12)) == "Nothing's planned for tonight yet.")
    }

    @Test func beforeTheAppHasWrittenOne() {
        #expect(TonightAnswer.text(nil, now: .now) == "Open Foon to see the plan.")
    }

    @Test func tonightTurnsOverAtTheHouseholdsMidnight() {
        let saved = snapshot([.init(date: today, title: "Tacos", isDish: true),
                              .init(date: today.adding(days: 1, calendar: calendar), title: "Chili", isDish: true)])
        // 11pm in Chicago on the 4th is the 5th in UTC: still Tacos.
        #expect(TonightAnswer.text(saved, now: at(day: 4, hour: 23)) == "Tonight: Tacos.")
        #expect(TonightAnswer.text(saved, now: at(day: 5, hour: 1)) == "Tonight: Chili.")
    }
}

/// What Siri says after "Add milk to the list" (#62).
@MainActor @Suite struct QuickListReplyTests {
    @Test func addedAndSent() {
        let result = QuickListAdder.Result(added: ["milk", "eggs"])
        #expect(result.spoken(waitingForSignal: false) == "Added milk and eggs.")
    }

    @Test func addedButWaitingForSignal() {
        let result = QuickListAdder.Result(added: ["milk"])
        #expect(result.spoken(waitingForSignal: true)
            == "Added milk. It'll reach the family when you're back online.")
    }

    @Test func aNewItemOfflineSaysWhy() {
        let result = QuickListAdder.Result(added: ["milk"], failed: ["kale"], newItemsOffline: true)
        #expect(result.spoken(waitingForSignal: true) == "Added milk. It'll reach the family when you're back online. "
            + "Couldn't add kale. New items need a connection; try again.")
        let none = QuickListAdder.Result(failed: ["kale"])
        #expect(none.spoken(waitingForSignal: false) == "Couldn't add kale. Try again.")
    }

    @Test func theMessageForTheListScreenIsUnchanged() {
        #expect(QuickListAdder.Result(added: ["milk"]).message == nil)
        #expect(QuickListAdder.Result(failed: ["kale"], newItemsOffline: true).message
            == "Couldn't add kale. New items need a connection; try again.")
    }

    @Test func addingKnownItemsReportsThemAdded() async throws {
        let household = UUID()
        let container = try SyncService.inMemoryContainer()
        let milk = UUID()
        let sync = SyncService(householdID: household, context: container.mainContext,
                                     client: .fake(snapshot: { throw URLError(.notConnectedToInternet) },
                                                   send: { _ in throw URLError(.notConnectedToInternet) }))
        let cached = CachedItem(ItemRow(id: milk, householdID: household, canonicalName: "Milk", category: .dairyEggs,
                                        keepOnHand: false, stockState: nil))
        let itemClient = ItemClient(update: { _, _ in }, ensure: { _, _, _ in throw URLError(.notConnectedToInternet) })
        let result = await QuickListAdder.add(["milk", "kale"], items: [cached], householdID: household,
                                              itemClient: itemClient, sync: sync)
        #expect(result.added == ["milk"])
        #expect(result.failed == ["kale"])
        #expect(result.newItemsOffline)
        #expect(sync.isOffline)
    }
}

/// One sync service per household for the whole app, so Siri's adds and the open app's never replay a change twice.
@MainActor @Suite struct SyncServicesTests {
    private let client = SyncClient.fake(snapshot: { throw URLError(.notConnectedToInternet) },
                                         send: { _ in throw URLError(.notConnectedToInternet) })

    @Test func theSameHouseholdGetsTheSameService() throws {
        let container = try SyncService.inMemoryContainer()
        let services = SyncServices()
        let household = UUID()
        let first = services.service(for: household, context: container.mainContext, client: client)
        let second = services.service(for: household, context: container.mainContext, client: client)
        #expect(first === second)
    }

    @Test func anotherHouseholdStopsTheOldOne() throws {
        let container = try SyncService.inMemoryContainer()
        let services = SyncServices()
        let first = services.service(for: UUID(), context: container.mainContext, client: client)
        let second = services.service(for: UUID(), context: container.mainContext, client: client)
        #expect(first !== second)
        #expect(first.isStopped)
        #expect(!second.isStopped)
    }

    @Test func afterStoppingTheNextAskGetsAFreshOne() throws {
        let container = try SyncService.inMemoryContainer()
        let services = SyncServices()
        let household = UUID()
        let first = services.service(for: household, context: container.mainContext, client: client)
        services.stop(first)
        #expect(first.isStopped)
        let second = services.service(for: household, context: container.mainContext, client: client)
        #expect(first !== second)
        #expect(!second.isStopped)
    }

    @Test func stoppingAnOldServiceLeavesTheCurrentOne() throws {
        let container = try SyncService.inMemoryContainer()
        let services = SyncServices()
        let household = UUID()
        let old = services.service(for: UUID(), context: container.mainContext, client: client)
        let current = services.service(for: household, context: container.mainContext, client: client)
        services.stop(old)
        #expect(services.service(for: household, context: container.mainContext, client: client) === current)
    }
}
