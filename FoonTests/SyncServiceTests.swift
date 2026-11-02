import Foundation
import PostgREST
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

    private func moveMilk(to line: UUID) -> OfflineChange {
        .addToList(householdID: household, itemID: eggsItem, list: .quick, urgency: .whenever, source: .manual,
                   note: nil, lineID: line, replacing: milkLine)
    }

    /// PostgREST finds the function by its argument names: leave out one that has no default and the call fails.
    @Test func aMoveNamesEveryArgumentEvenWithNoNote() throws {
        let params = MoveToQuickListParams(targetLine: UUID(), targetHousehold: UUID(), targetItem: UUID(),
                                           itemNote: nil, lineID: UUID(), itemQuantity: nil)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["target_line", "target_household", "target_item", "item_note", "line_id",
                                                     "item_quantity"])
        #expect(body?["item_note"] is NSNull)
    }

    private func openLines(_ container: ModelContainer, item: UUID) throws -> [CachedListItem] {
        try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).filter { $0.itemID == item && $0.checkedAt == nil }
    }

    @Test func outPutsAStapleOnTheQuickListOffline() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .out)
        let lines = try openLines(container, item: eggsItem)
        #expect(lines.map(\.list) == [.quick])
        #expect(lines.map(\.sourceRaw) == [ListItemSource.staple.rawValue])
        #expect(service.stockState(eggsItem) == .out)
    }

    @Test func lowDoesntListIt() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .low)
        #expect(try openLines(container, item: eggsItem).isEmpty)
    }

    @Test func outDoesntListItTwice() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: milkItem, state: .out)
        #expect(try openLines(container, item: milkItem).map(\.id) == [milkLine])
    }

    @Test func backInTakesOffOnlyTheStaplesLine() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .out)
        await service.setStock(itemID: eggsItem, state: .in)
        #expect(try openLines(container, item: eggsItem).isEmpty, "it was only on the list because it was out")
        await service.setStock(itemID: milkItem, state: .out)
        await service.setStock(itemID: milkItem, state: .in)
        #expect(try openLines(container, item: milkItem).map(\.id) == [milkLine], "someone added this one by hand")
    }

    @Test func aRestockOnlyTouchesAStapleOnThisPhone() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: milkItem, state: .low)
        await service.perform(.restock(itemID: milkItem, ifWas: .low))
        #expect(service.stockState(milkItem) == .in)
        await service.perform(.restock(itemID: eggsItem, ifWas: nil))
        #expect(service.isKeptOnHand(eggsItem) == false, "not a staple here; the server says if it is one now")
        #expect(service.stockState(eggsItem) == nil)
    }

    @Test func aRestockTheServerPassedOverShowsTheServersStock() async throws {
        let container = try SyncService.inMemoryContainer()
        let pulls = Mutex(0)
        let household = household, milkItem = milkItem, base = snapshot
        // This phone saw milk low; by the time the check-off is sent, another phone has marked it out, so the server keeps out.
        let client = SyncClient.fake(snapshot: {
            let state: StockState = pulls.withLock { $0 += 1; return $0 } == 1 ? .low : .out
            return SyncSnapshot(plan: base.plan, nights: [], listItems: base.listItems,
                                items: base.items.map { $0.id == milkItem ? ItemRow(id: milkItem, householdID: household,
                                                                                    canonicalName: "Milk", category: .dairyEggs,
                                                                                    keepOnHand: true, stockState: state) : $0 })
        }, send: { _ in })
        let service = makeService(container: container, client: client)
        await service.pull()
        await service.perform(.restock(itemID: milkItem, ifWas: .low))
        #expect(service.stockState(milkItem) == .out)
    }

    private func milkSnapshot(_ state: StockState) -> SyncSnapshot {
        let base = snapshot
        return SyncSnapshot(plan: base.plan, nights: [], listItems: base.listItems,
                            items: base.items.map { $0.id == milkItem ? ItemRow(id: milkItem, householdID: household,
                                                                                canonicalName: "Milk", category: .dairyEggs,
                                                                                keepOnHand: true, stockState: state) : $0 })
    }

    @Test func aQueuedRestockDoesntHideStockAnotherPhoneChanged() async throws {
        let container = try SyncService.inMemoryContainer()
        let pulls = Mutex(0)
        let low = milkSnapshot(.low), out = milkSnapshot(.out)
        let service = makeService(container: container, client: .fake(snapshot: {
            pulls.withLock { $0 += 1; return $0 } == 1 ? low : out
        }, send: { _ in throw URLError(.notConnectedToInternet) }))
        await service.pull()
        await service.perform(.restock(itemID: milkItem, ifWas: .low))
        #expect(service.stockState(milkItem) == .in)
        await service.pull()
        #expect(service.stockState(milkItem) == .out, "the server will keep out, so this phone shows it while the restock waits")
    }

    @Test func checkingOffANonStapleDoesntPull() async throws {
        let container = try SyncService.inMemoryContainer()
        let pulls = Mutex(0)
        let base = snapshot
        let service = makeService(container: container, client: .fake(snapshot: {
            pulls.withLock { $0 += 1 }
            return base
        }, send: { _ in }))
        await service.pull()
        await service.perform(.restock(itemID: eggsItem, ifWas: nil))
        #expect(pulls.withLock { $0 } == 1, "a pull per check-off would double the work in the store")
    }

    @Test func turningKeepOnHandBackOnTakesNothingOff() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .out)
        await service.setStock(itemID: eggsItem, state: nil)
        await service.setStock(itemID: eggsItem, state: .in)
        #expect(try openLines(container, item: eggsItem).count == 1, "nobody said it was bought")
    }

    @Test func theServerDecidesWhetherAStapleLineGoes() async throws {
        let container = try SyncService.inMemoryContainer()
        let line = UUID()
        let pulls = Mutex(0)
        let sent = Mutex<[OfflineChange]>([])
        let household = household, eggsItem = eggsItem, base = snapshot
        // This phone saw a staple's line; by the time it's sent, the server's line is one someone added by hand.
        let client = SyncClient.fake(snapshot: {
            let source: ListItemSource = pulls.withLock { $0 += 1; return $0 } == 1 ? .staple : .manual
            return SyncSnapshot(plan: base.plan, nights: [], listItems: base.listItems + [
                ListItemRow(id: line, householdID: household, itemID: eggsItem, list: .quick, urgency: .whenever, source: source,
                            note: nil, checkedAt: nil)
            ], items: base.items.map { $0.id == eggsItem ? ItemRow(id: eggsItem, householdID: household, canonicalName: "Eggs",
                                                                     category: .dairyEggs, keepOnHand: true, stockState: .out) : $0 })
        }, send: { change in
            sent.withLock { $0.append(change) }
        })
        let service = makeService(container: container, client: client)
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .in)
        #expect(sent.withLock { $0 }.contains(.removeStapleLine(listItemID: line)))
        #expect(try openLines(container, item: eggsItem).map(\.id) == [line], "the server kept it, and the phone shows that at once")
    }

    @Test func approvingTakesAStapleOffTheQuickListWhenTheWeekHasIt() async throws {
        let container = try SyncService.inMemoryContainer()
        let quick = UUID(), weekly = UUID(), other = UUID()
        let household = household, eggsItem = eggsItem, milkItem = milkItem, base = snapshot
        let service = makeService(container: container, client: .fake(snapshot: {
            SyncSnapshot(plan: base.plan, nights: [], listItems: [
                ListItemRow(id: quick, householdID: household, itemID: eggsItem, list: .quick, urgency: .whenever, source: .staple,
                            note: nil, checkedAt: nil),
                ListItemRow(id: weekly, householdID: household, itemID: eggsItem, list: .weekly, urgency: .whenever, source: .plan,
                            note: nil, checkedAt: nil),
                ListItemRow(id: other, householdID: household, itemID: milkItem, list: .quick, urgency: .whenever, source: .staple,
                            note: nil, checkedAt: nil)
            ], items: base.items)
        }, send: { _ in throw URLError(.notConnectedToInternet) }))
        await service.pullAfterApproving()
        let open = try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).map(\.id)
        #expect(Set(open) == [weekly, other])
    }

    /// The approve's write sets off a sync through Realtime, and that pull can be under way, without the new list, when the
    /// approve asks for its own.
    @Test func approvingWaitsForAPullThatHasTheNewList() async throws {
        let container = try SyncService.inMemoryContainer()
        let quick = UUID(), weekly = UUID()
        let pulls = Mutex(0)
        let removed = Mutex(false)
        let household = household, eggsItem = eggsItem, base = snapshot
        let service = makeService(container: container, client: .fake(snapshot: {
            let pull = pulls.withLock { $0 += 1; return $0 }
            let staple = removed.withLock { $0 } ? [] : [ListItemRow(
                id: quick, householdID: household, itemID: eggsItem, list: .quick, urgency: .whenever, source: .staple, note: nil,
                checkedAt: nil)]
            if pull == 1 {
                try await Task.sleep(for: .milliseconds(200))
                return SyncSnapshot(plan: base.plan, nights: [], listItems: staple, items: base.items)
            }
            return SyncSnapshot(plan: base.plan, nights: [], listItems: staple + [ListItemRow(
                id: weekly, householdID: household, itemID: eggsItem, list: .weekly, urgency: .whenever, source: .plan, note: nil,
                checkedAt: nil)], items: base.items)
        }, send: { change in
            if change == .removeStapleLine(listItemID: quick) { removed.withLock { $0 = true } }
        }))
        let earlier = Task { await service.pull() }
        try await Task.sleep(for: .milliseconds(50))
        await service.pullAfterApproving()
        await earlier.value
        let open = try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).map(\.id)
        #expect(open == [weekly])
    }

    @Test func somethingAddedToAStaplesLineMakesItThatLine() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        await service.setStock(itemID: eggsItem, state: .out)
        await service.addToList(itemID: eggsItem, list: .quick, urgency: .tonight, source: .pivot, note: "Get egg-free (Sam)")
        await service.setStock(itemID: eggsItem, state: .in)
        let lines = try openLines(container, item: eggsItem)
        #expect(lines.map(\.note) == ["Get egg-free (Sam)"], "tonight's need stays when the staple's back in")
    }

    @Test func aMoveShowsAtOnceOffline() async throws {
        let container = try SyncService.inMemoryContainer()
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { _ in
            throw URLError(.notConnectedToInternet)
        }))
        await service.pull()
        let line = UUID()
        await service.perform(moveMilk(to: line))
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).map(\.id) == [line])
        #expect(service.pendingCount == 1)
    }

    @Test func aRefusedChangeBringsBackWhatTheServerHas() async throws {
        let container = try SyncService.inMemoryContainer()
        let sent = Mutex<[OfflineChange]>([])
        let service = makeService(container: container, client: .fake(snapshot: { snapshot }, send: { change in
            sent.withLock { $0.append(change) }
            throw PostgrestError(code: "23503", message: "refused")
        }))
        await service.pull()
        await service.perform(moveMilk(to: UUID()))
        #expect(sent.withLock { $0.count } == 1, "one change: nothing else goes to the server to remove the line")
        #expect(service.pendingCount == 0, "the server refused it, so there's no retry")
        #expect(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).map(\.id) == [milkLine],
                "and the line is back without waiting for anything else to pull")
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
