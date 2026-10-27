import Foundation
import Network
import Supabase
import Synchronization

/// Server access for the offline cache, as closures so tests and previews can swap them out.
struct SyncClient: Sendable {
    /// The current week (the latest plan that has started and hasn't ended), its nights, the open
    /// lists plus the last day's check-offs, and the household's items.
    var fetchSnapshot: @Sendable (_ householdID: UUID, _ today: CalendarDay) async throws -> SyncSnapshot
    /// Sends one change. Returns the existing line's id when the server merged an added line into it.
    var send: @Sendable (_ change: OfflineChange) async throws -> UUID?
    /// Fires once the subscription is ready, then whenever the household's lists or items change on
    /// the server (Realtime). Payloads are ignored: the service re-pulls, which also keeps it safe
    /// from Realtime's unfiltered delete events (#6).
    var listChanges: @Sendable (_ householdID: UUID) -> AsyncStream<Void>
    /// Fires when the network comes back, so queued changes go out without waiting for another tap.
    var reconnects: @Sendable () -> AsyncStream<Void>
}

extension SyncClient {
    static func live(_ client: SupabaseClient) -> SyncClient {
        SyncClient(
            fetchSnapshot: { householdID, today in
                let plans: [PlanRow] = try await client.from("plans")
                    .select("id, household_id, week_start, approved_at")
                    .eq("household_id", value: householdID)
                    .lte("week_start", value: today.isoString)
                    .order("week_start", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                let plan = plans.first.flatMap { $0.weekStart.adding(days: 6) >= today ? $0 : nil }

                let nights: [NightRow] = if let plan {
                    try await client.from("plan_nights")
                        .select("id, plan_id, date, effort, dinner_time, meal_id, quick_pick, locked, meals(name)")
                        .eq("plan_id", value: plan.id)
                        .order("date")
                        .execute()
                        .value
                } else { [] }

                let dayAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
                let listItems: [ListItemRow] = try await client.from("list_items")
                    .select("id, household_id, item_id, list, urgency, source, note, quantity, checked_at")
                    .eq("household_id", value: householdID)
                    .or("checked_at.is.null,checked_at.gte.\(dayAgo)")
                    .execute()
                    .value

                let items: [ItemRow] = try await client.from("items")
                    .select("id, household_id, canonical_name, category, keep_on_hand, stock_state, note")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value

                return SyncSnapshot(plan: plan, nights: nights, listItems: listItems, items: items)
            },
            send: { change in
                switch change {
                case .setChecked(let listItemID, let checked):
                    // The database stamps who checked it and when.
                    try await client.from("list_items")
                        .update(CheckPatch(checkedAt: checked ? Date() : nil))
                        .eq("id", value: listItemID)
                        .execute()
                    return nil
                case .addToList(let householdID, let itemID, let list, let urgency, let source, let note, let lineID):
                    let line: LineID = try await client.rpc("add_to_list", params: AddToListParams(
                        targetHousehold: householdID, targetItem: itemID, targetList: list,
                        itemUrgency: urgency, itemSource: source, itemNote: note, lineID: lineID
                    )).select("id").single().execute().value
                    return line.id == lineID ? nil : line.id
                case .setStock(let itemID, let state):
                    try await client.from("items")
                        .update(StockPatch(stockState: state, keepOnHand: state != nil))
                        .eq("id", value: itemID)
                        .execute()
                    return nil
                }
            },
            listChanges: { householdID in
                // A unique topic per subscription: the client reuses channels by topic, and a reused or
                // just-removed channel would silently stop delivering.
                let channel = client.channel("household-\(householdID.uuidString.lowercased())-\(UUID().uuidString)")
                let household = RealtimePostgresFilter.eq("household_id", value: householdID)
                let lines = channel.postgresChange(AnyAction.self, schema: "public", table: "list_items", filter: household)
                let items = channel.postgresChange(AnyAction.self, schema: "public", table: "items", filter: household)
                return AsyncStream { continuation in
                    let listening = Task {
                        try? await channel.subscribeWithError()
                        // One signal once subscribed, so a change made before the subscription was ready is pulled too.
                        continuation.yield()
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { for await _ in lines { continuation.yield() } }
                            group.addTask { for await _ in items { continuation.yield() } }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        listening.cancel()
                        Task { await client.removeChannel(channel) }
                    }
                }
            },
            reconnects: {
                AsyncStream { continuation in
                    let monitor = NWPathMonitor()
                    let wasOnline = Mutex<Bool?>(nil)
                    monitor.pathUpdateHandler = { path in
                        let online = path.status == .satisfied
                        let before = wasOnline.withLock { state in
                            defer { state = online }
                            return state
                        }
                        if online, before == false { continuation.yield() }
                    }
                    monitor.start(queue: DispatchQueue(label: "com.andrikanich.foon.network"))
                    continuation.onTermination = { _ in monitor.cancel() }
                }
            }
        )
    }
}

private struct LineID: Decodable { let id: UUID }

// Patches send nulls explicitly so clearing a value reaches the database.

private struct CheckPatch: Encodable, Sendable {
    let checkedAt: Date?
    enum CodingKeys: String, CodingKey { case checkedAt = "checked_at" }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checkedAt, forKey: .checkedAt)
    }
}

private struct StockPatch: Encodable, Sendable {
    let stockState: StockState?
    let keepOnHand: Bool
    enum CodingKeys: String, CodingKey {
        case stockState = "stock_state"
        case keepOnHand = "keep_on_hand"
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stockState, forKey: .stockState)
        try container.encode(keepOnHand, forKey: .keepOnHand)
    }
}

private struct AddToListParams: Encodable, Sendable {
    let targetHousehold: UUID
    let targetItem: UUID
    let targetList: ListKind
    let itemUrgency: ListUrgency
    let itemSource: ListItemSource
    let itemNote: String?
    let lineID: UUID

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case targetItem = "target_item"
        case targetList = "target_list"
        case itemUrgency = "item_urgency"
        case itemSource = "item_source"
        case itemNote = "item_note"
        case lineID = "line_id"
    }

    // PostgREST matches functions by argument names, so every argument is sent, null included.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetHousehold, forKey: .targetHousehold)
        try container.encode(targetItem, forKey: .targetItem)
        try container.encode(targetList, forKey: .targetList)
        try container.encode(itemUrgency, forKey: .itemUrgency)
        try container.encode(itemSource, forKey: .itemSource)
        try container.encode(itemNote, forKey: .itemNote)
        try container.encode(lineID, forKey: .lineID)
    }
}

extension SyncClient {
    /// No server: an empty week, no changes, no reconnects.
    static let preview = SyncClient(
        fetchSnapshot: { _, _ in SyncSnapshot(plan: nil, nights: [], listItems: [], items: []) },
        send: { _ in nil },
        listChanges: { _ in AsyncStream { $0.finish() } },
        reconnects: { AsyncStream { $0.finish() } }
    )
}
