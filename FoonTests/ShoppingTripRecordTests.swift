import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

/// Finish trip records that the household finished a trip (#260): once, even from a phone that was offline.
@MainActor
struct ShoppingTripRecordTests {
    private let household = UUID()

    /// The container must outlive the service: SwiftData traps when a context's container is gone.
    private func service(_ container: ModelContainer, _ client: SyncClient) -> SyncService {
        SyncService(householdID: household, context: container.mainContext, client: client,
                    today: { CalendarDay(year: 2026, month: 11, day: 3) })
    }

    /// PostgREST finds the function by its argument names.
    @Test func theRecordNamesEveryArgument() throws {
        let params = RecordShoppingTripParams(tripID: UUID(), targetHousehold: UUID(), tripFinishedAt: .now)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["trip_id", "target_household", "trip_finished_at"])
    }

    @Test func aQueuedFinishSurvivesBeingStored() throws {
        let change = OfflineChange.finishTrip(householdID: household, tripID: UUID(),
                                              finishedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let decoded = try JSONDecoder().decode(OfflineChange.self, from: JSONEncoder().encode(change))
        #expect(decoded == change)
    }

    @Test func aFinishMadeOfflineIsSentOnceWhenThePhoneReconnects() async throws {
        let online = Mutex(false)
        let sent = Mutex<[OfflineChange]>([])
        let container = try SyncService.inMemoryContainer()
        let empty = SyncSnapshot(plan: nil, nights: [], listItems: [], items: [])
        let service = service(container, .fake(snapshot: { empty }, send: { change in
            guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
            sent.withLock { $0.append(change) }
        }))
        let finish = OfflineChange.finishTrip(householdID: household, tripID: UUID(), finishedAt: .now)

        await service.perform(finish)
        #expect(service.pendingCount == 1, "offline, it waits")
        #expect(sent.withLock { $0 }.isEmpty)

        online.withLock { $0 = true }
        await service.replayPending()
        await service.replayPending()
        #expect(sent.withLock { $0 } == [finish], "sent once when back online")
        #expect(service.pendingCount == 0)
    }

    @Test func finishingATripMakesOneRecordWithANewID() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ListBoard.finishTrip(householdID: household, at: at)
        let second = ListBoard.finishTrip(householdID: household, at: at)
        guard case .finishTrip(let firstHousehold, let firstTrip, let firstAt) = first,
              case .finishTrip(_, let secondTrip, _) = second else {
            Issue.record("not a finished trip")
            return
        }
        #expect(firstHousehold == household)
        #expect(firstAt == at)
        #expect(firstTrip != secondTrip, "each finish is its own trip")
    }
}
