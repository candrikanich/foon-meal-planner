import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

@MainActor
struct SyncServiceTests {
    private let household = UUID()
    private let milkItem = UUID()
    private let eggsItem = UUID()
    private let milkLine = UUID()

    nonisolated private var snapshot: SyncSnapshot {
        SyncSnapshot(
            plan: PlanRow(id: UUID(), householdID: household, weekStart: CalendarDay(year: 2026, month: 11, day: 1), approvedAt: nil),
            nights: [],
            listItems: [ListItemRow(id: milkLine, householdID: household, itemID: milkItem, list: .quick, urgency: .whenever,
                                    source: .manual, note: nil, checkedAt: nil)],
            items: [ItemRow(id: milkItem, householdID: household, canonicalName: "Milk", category: .dairyEggs,
                            keepOnHand: true, stockState: .in),
                    ItemRow(id: eggsItem, householdID: household, canonicalName: "Eggs", category: .dairyEggs,
                            keepOnHand: false, stockState: nil)]
        )
    }

    private func makeService(container: ModelContainer, client: SyncClient) -> SyncService {
        SyncService(householdID: household, context: container.mainContext, client: client,
                    today: { CalendarDay(year: 2026, month: 11, day: 3) })
    }

    @Test func pullCachesTheWeekAndTheList() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }))
        await service.pull()
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedPlan>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).map(\.itemName) == ["Milk"])
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedItem>()).count == 2)
        #expect(service.lastPulled != nil)
    }

    @Test func aNewPullReplacesTheOldSnapshot() async throws {
        let container = try SyncService.inMemoryContainer()
        let current = Mutex(snapshot)
        let service = makeService(container: container, client: .fake(snapshot: { current.withLock { $0 } }))
        await service.pull()
        current.withLock { $0.listItems = [] }
        await service.pull()
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).isEmpty)
    }

    @Test func anOfflineCheckOffShowsAtOnceAndSyncsLater() async throws {
        let container = try SyncService.inMemoryContainer()
        let online = Mutex(false)
        let sent = Mutex<[OfflineChange]>([])
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { change in
            guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
            sent.withLock { $0.append(change) }
        }))
        await service.pull()

        await service.perform(.setChecked(listItemID: milkLine, checked: true))
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).first?.checkedAt != nil)
        #expect(service.pendingCount == 1)

        await service.perform(.setChecked(listItemID: milkLine, checked: false))
        online.withLock { $0 = true }
        await service.replayPending()
        #expect(sent.withLock { $0 } == [.setChecked(listItemID: milkLine, checked: true),
                                         .setChecked(listItemID: milkLine, checked: false)])
        #expect(service.pendingCount == 0)
    }

    @Test func pendingChangesStayVisibleAfterAPull() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(
            snapshot: { snapshot }, send: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await service.pull()
        await service.perform(.setStock(itemID: milkItem, state: .out))
        await service.pull()
        let milk = try container.mainContext.fetch(FetchDescriptor<CachedItem>()).first { $0.id == milkItem }
        #expect(milk?.stockState == .out, "the server hasn't seen the tap yet, so the cache keeps it")
    }

    @Test func theQueueSurvivesARelaunch() async throws {
        let container = try SyncService.inMemoryContainer()
        let offline = makeService(container: container, client: .fake(
            snapshot: { snapshot }, send: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await offline.pull()
        await offline.perform(.setChecked(listItemID: milkLine, checked: true))

        let sent = Mutex<[OfflineChange]>([])
        let relaunched = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { change in
            sent.withLock { $0.append(change) }
        }))
        await relaunched.replayPending()
        #expect(sent.withLock { $0 } == [.setChecked(listItemID: milkLine, checked: true)])
    }

    @Test func addingToTheListOfflineMergesWithAnOpenEntry() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(
            snapshot: { snapshot }, send: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await service.pull()
        await service.perform(.addToList(householdID: household, itemID: milkItem, list: .quick, urgency: .tonight,
                                         source: .pivot, note: nil, lineID: UUID()))
        await service.perform(.addToList(householdID: household, itemID: eggsItem, list: .quick, urgency: .whenever,
                                         source: .manual, note: nil, lineID: UUID()))
        let lines = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        #expect(lines.count == 2, "milk merged into its open line; eggs added")
        #expect(lines.first { $0.itemID == milkItem }?.urgency == .tonight)
    }

    @Test func aLineAddedOfflineCanBeCheckedOffBeforeItSyncs() async throws {
        let container = try SyncService.inMemoryContainer()
        let online = Mutex(false)
        let sent = Mutex<[OfflineChange]>([])
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { change in
            guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
            sent.withLock { $0.append(change) }
        }))
        await service.pull()
        let line = await service.addToList(itemID: eggsItem, list: .quick)
        await service.perform(.setChecked(listItemID: line, checked: true))
        online.withLock { $0 = true }
        await service.replayPending()
        #expect(sent.withLock { $0 }.last == .setChecked(listItemID: line, checked: true),
                "the check-off targets the id the line was created with")
    }

    @Test func aServerMergeRepointsTheCachedLine() async throws {
        let container = try SyncService.inMemoryContainer()
        let existing = UUID()
        let service = makeService(container: container, client: .fake(
            snapshot: { snapshot },
            mergedInto: { change in if case .addToList = change { existing } else { nil } }
        ))
        await service.pull()
        _ = await service.addToList(itemID: eggsItem, list: .quick)
        let lines = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        #expect(lines.contains { $0.id == existing && $0.itemID == eggsItem })
    }

    @Test func changesMadeDuringAReplayAreSentOnceInOrder() async throws {
        let container = try SyncService.inMemoryContainer()
        let sent = Mutex<[OfflineChange]>([])
        let (gate, release) = AsyncStream<Void>.makeStream()
        let firstCall = Mutex(true)
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { change in
            if firstCall.withLock({ let first = $0; $0 = false; return first }) {
                for await _ in gate { break }  // hold the first send until the test releases it
            }
            sent.withLock { $0.append(change) }
        }))
        await service.pull()
        let first = Task { await service.perform(.setChecked(listItemID: milkLine, checked: true)) }
        await Task.yield()
        let second = Task { await service.perform(.setChecked(listItemID: milkLine, checked: false)) }
        await Task.yield()
        release.yield()
        await first.value
        await second.value
        #expect(sent.withLock { $0 } == [.setChecked(listItemID: milkLine, checked: true),
                                         .setChecked(listItemID: milkLine, checked: false)])
        #expect(service.pendingCount == 0)
    }

    @Test func comingBackOnlineReplaysTheQueue() async throws {
        let container = try SyncService.inMemoryContainer()
        let online = Mutex(false)
        let sent = Mutex<[OfflineChange]>([])
        let (reconnects, signal) = AsyncStream<Void>.makeStream()
        let service = makeService(container: container, client: .fake(
            snapshot: { snapshot },
            send: { change in
                guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                sent.withLock { $0.append(change) }
            },
            reconnects: { reconnects }
        ))
        await service.pull()
        await service.perform(.setChecked(listItemID: milkLine, checked: true))
        #expect(service.pendingCount == 1)
        let running = Task { await service.start() }
        online.withLock { $0 = true }
        signal.yield()
        signal.finish()
        await running.value
        #expect(sent.withLock { $0 } == [.setChecked(listItemID: milkLine, checked: true)])
        #expect(service.pendingCount == 0)
    }

    @Test func aRealtimeChangeTriggersAPull() async throws {
        let container = try SyncService.inMemoryContainer()
        let pulls = Mutex(0)
        let (changes, signal) = AsyncStream<Void>.makeStream()
        let service = makeService(container: container, client: .fake(
            snapshot: { pulls.withLock { $0 += 1 }; return snapshot },
            listChanges: { _ in changes }
        ))
        let running = Task { await service.start() }
        signal.yield()
        signal.finish()
        await running.value
        #expect(pulls.withLock { $0 } == 2, "one pull at launch, one for the change")
    }
}

extension SyncClient {
    static func fake(
        snapshot: @escaping @Sendable () async throws -> SyncSnapshot,
        send: @escaping @Sendable (OfflineChange) async throws -> Void = { _ in },
        mergedInto: @escaping @Sendable (OfflineChange) -> UUID? = { _ in nil },
        listChanges: @escaping @Sendable (UUID) -> AsyncStream<Void> = { _ in AsyncStream { $0.finish() } },
        reconnects: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    ) -> SyncClient {
        SyncClient(
            fetchSnapshot: { _, _ in try await snapshot() },
            send: { change in
                try await send(change)
                return mergedInto(change)
            },
            listChanges: listChanges,
            reconnects: reconnects
        )
    }
}

@MainActor
struct SyncCacheClearingTests {
    @Test func signingOutClearsEverythingCached() async throws {
        let container = try SyncService.inMemoryContainer()
        let household = UUID()
        let service = SyncService(householdID: household, context: container.mainContext, client: .fake(
            snapshot: {
                SyncSnapshot(plan: nil, nights: [],
                             listItems: [ListItemRow(id: UUID(), householdID: household, itemID: UUID(), list: .quick,
                                                     urgency: .whenever, source: .manual, note: nil, checkedAt: nil)],
                             items: [])
            },
            send: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await service.pull()
        await service.perform(.setStock(itemID: UUID(), state: .low))
        try SyncService.clearCache(in: container.mainContext)
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }
}

@MainActor
struct SyncIsolationTests {
    nonisolated private func snapshot(_ household: UUID) -> SyncSnapshot {
        SyncSnapshot(plan: nil, nights: [],
                     listItems: [ListItemRow(id: UUID(), householdID: household, itemID: UUID(), list: .quick,
                                             urgency: .whenever, source: .manual, note: nil, checkedAt: nil)],
                     items: [])
    }

    @Test func aPullThatFinishesAfterStoppingWritesNothing() async throws {
        let container = try SyncService.inMemoryContainer()
        let household = UUID()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let service = SyncService(householdID: household, context: container.mainContext, client: .fake(snapshot: {
            for await _ in gate { break }  // hold the fetch until the test releases it
            return snapshot(household)
        }))
        let pulling = Task { await service.pull() }
        await Task.yield()
        service.stop()  // signed out while the fetch was in flight
        try SyncService.clearCache(in: container.mainContext)
        release.yield()
        await pulling.value
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).isEmpty,
                "the late snapshot must not refill the wiped cache")
    }

    @Test func startingForAHouseholdRemovesAnyOtherHouseholdsData() async throws {
        let container = try SyncService.inMemoryContainer()
        let previous = UUID()
        let previousService = SyncService(householdID: previous, context: container.mainContext, client: .fake(
            snapshot: { snapshot(previous) }, send: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await previousService.pull()
        await previousService.perform(.setStock(itemID: UUID(), state: .low))

        _ = SyncService(householdID: UUID(), context: container.mainContext, client: .fake(snapshot: { snapshot(UUID()) }))
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }
}
