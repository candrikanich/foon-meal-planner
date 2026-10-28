import Foundation
import Supabase
import SwiftData
import Synchronization
import Testing
@testable import Foon

/// The offline cache against the local stack: the real snapshot query, replay through PostgREST, and
/// Realtime driving a re-pull. Needs `supabase start`; enable with `TEST_RUNNER_FOON_LOCAL_SUPABASE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOON_LOCAL_SUPABASE"] != nil))
@MainActor
struct SyncLiveTests {
    @Test func pullsReplaysAndFollowsRealtime() async throws {
        let config = try SupabaseConfig.fromMainBundle()
        let supabase = SupabaseClient(
            supabaseURL: config.url, supabaseKey: config.anonKey,
            options: SupabaseClientOptions(auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true))
        )
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: "local-test-password-1")
        let household = try await HouseholdClient.live(supabase).createHousehold("Sync family", nil, "Ann", HouseholdSettings())

        // A week with tonight's tacos, and milk on the quick list.
        let today = CalendarDay(Date())
        let tacos: IDRow = try await supabase.from("meals")
            .insert(["household_id": household.id.uuidString, "name": "Tacos"]).select("id").single().execute().value
        let plan: IDRow = try await supabase.from("plans")
            .insert(["household_id": household.id.uuidString, "week_start": today.isoString]).select("id").single().execute().value
        try await supabase.from("plan_nights").insert([
            "household_id": household.id.uuidString, "plan_id": plan.id.uuidString,
            "date": today.isoString, "meal_id": tacos.id.uuidString
        ]).execute()
        let milk: IDRow = try await supabase.rpc("ensure_item", params: ["target_household": household.id.uuidString,
                                                                       "item_name": "Milk"]).select("id").single().execute().value
        try await SyncClient.live(supabase).send(.addToList(householdID: household.id, itemID: milk.id, list: .quick,                                                            urgency: .whenever, source: .manual, note: nil, lineID: UUID()))

        let container = try SyncService.inMemoryContainer()
        let service = SyncService(householdID: household.id, context: container.mainContext, client: .live(supabase))
        await service.pull()
        let night = try #require(try container.mainContext.fetch(FetchDescriptor<CachedNight>()).first)
        #expect(night.mealName == "Tacos", "nights carry their meal's name")
        let line = try #require(try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).first)
        #expect(line.itemName == "Milk")

        // A check-off replays through PostgREST, and the database stamps it.
        await service.perform(.setChecked(listItemID: line.id, checked: true))
        #expect(service.pendingCount == 0)
        let checked: [CheckRow] = try await supabase.from("list_items").select("checked_at, checked_by")
            .eq("id", value: line.id).execute().value
        #expect(checked.first?.checkedAt != nil)

        // Realtime: a list change made elsewhere reaches the running service.
        let pulledBefore = try #require(service.lastPulled)
        let following = Task { await service.start() }
        // start() pulls at launch (and again once subscribed, which can land in the same sampling gap, so only the
        // first is counted). The probe below is what proves Realtime is delivering.
        var pulledAtLaunch = false
        for _ in 0..<100 where !pulledAtLaunch {
            try await Task.sleep(for: .milliseconds(50))
            pulledAtLaunch = (service.lastPulled ?? pulledBefore) > pulledBefore
        }
        #expect(pulledAtLaunch, "start() pulls at launch")
        // Realtime starts streaming database changes a moment after it reports the channel subscribed, so a change
        // made right then can be missed (the app catches up on the next change or foreground). Probe until a change
        // made elsewhere actually arrives, then test with a fresh one.
        let probe: IDRow = try await supabase.rpc("ensure_item", params: ["target_household": household.id.uuidString,
                                                                        "item_name": "Probe"]).select("id").single().execute().value
        // The probe's own change must show up in the cache, twice in a row: the one pull start() makes when
        // subscribed can account for one, so at least one came from a Realtime event.
        var deliveredInARow = 0
        for attempt in 0..<40 where deliveredInARow < 2 {
            let state: StockState = attempt.isMultiple(of: 2) ? .low : .out
            try await SyncClient.live(supabase).send(.setStock(itemID: probe.id, state: state))
            var arrived = false
            for _ in 0..<20 where !arrived {
                try await Task.sleep(for: .milliseconds(50))
                arrived = try container.mainContext.fetch(FetchDescriptor<CachedItem>())
                    .first { $0.id == probe.id }?.stockState == state
            }
            deliveredInARow = arrived ? deliveredInARow + 1 : 0
        }
        let streaming = deliveredInARow == 2
        try #require(streaming, "Realtime never delivered a change")
        let eggs: IDRow = try await supabase.rpc("ensure_item", params: ["target_household": household.id.uuidString,
                                                                       "item_name": "Eggs"]).select("id").single().execute().value
        try await SyncClient.live(supabase).send(.addToList(householdID: household.id, itemID: eggs.id, list: .quick,
                                                            urgency: .tonight, source: .pivot, note: nil, lineID: UUID()))
        var sawEggs = false
        for _ in 0..<50 where !sawEggs {
            try await Task.sleep(for: .milliseconds(100))
            sawEggs = try container.mainContext.fetch(FetchDescriptor<CachedListItem>()).contains { $0.itemName == "Eggs" }
        }
        #expect(sawEggs, "Realtime triggered a pull that cached the new line")

        // A staple tapped low elsewhere reaches the cache (items stream over Realtime too).
        try await SyncClient.live(supabase).send(.setStock(itemID: milk.id, state: .low))
        var sawLow = false
        for _ in 0..<50 where !sawLow {
            try await Task.sleep(for: .milliseconds(100))
            sawLow = try container.mainContext.fetch(FetchDescriptor<CachedItem>()).first { $0.id == milk.id }?.stockState == .low
        }
        #expect(sawLow, "a stock change made elsewhere arrives over Realtime")

        // A line added through the service keeps its id on the server, so a check-off on it lands.
        let bread: IDRow = try await supabase.rpc("ensure_item", params: ["target_household": household.id.uuidString,
                                                                        "item_name": "Bread"]).select("id").single().execute().value
        let breadLine = await service.addToList(itemID: bread.id, list: .weekly)
        await service.perform(.setChecked(listItemID: breadLine, checked: true))
        // A Realtime pull may be running, so the replay can land just after perform returns: poll the server.
        var breadChecked = false
        for _ in 0..<50 where !breadChecked {
            let rows: [CheckRow] = try await supabase.from("list_items").select("checked_at, checked_by")
                .eq("id", value: breadLine).execute().value
            breadChecked = rows.first?.checkedAt != nil
            if !breadChecked { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(breadChecked, "the check-off reached the row the device created")
        following.cancel()
    }
}

private struct IDRow: Decodable { let id: UUID }

private struct CheckRow: Decodable {
    let checkedAt: Date?
    enum CodingKeys: String, CodingKey { case checkedAt = "checked_at" }
}

/// Keeps the test user's session out of the Keychain.
private final class MemoryStorage: AuthLocalStorage {
    private let values = Mutex<[String: Data]>([:])
    func store(key: String, value: Data) throws { values.withLock { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}
