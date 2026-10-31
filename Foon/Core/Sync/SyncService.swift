import Foundation
import Observation
import SwiftData

/// Keeps the current week and the lists on the device. Pulls on launch, when lists or items change
/// on the server, and when the network comes back; writes apply to the cache at once and replay to
/// the server in order, so store mode works without signal.
///
/// Every replay and pull goes through one runner, one at a time: overlapping runs could send a
/// change twice, deliver changes out of order, or let an older snapshot wipe a change just sent.
@Observable @MainActor
final class SyncService {
    static let schema = Schema([CachedPlan.self, CachedNight.self, CachedListItem.self, CachedItem.self, PendingChange.self,
                                CachedReminders.self, NotificationRecord.self])

    private(set) var lastPulled: Date?
    private(set) var pendingCount = 0
    /// True while changes are waiting on the network.
    private(set) var isOffline = false

    let householdID: UUID
    private let context: ModelContext
    private let client: SyncClient
    private let today: @Sendable () -> CalendarDay

    /// Set on sign-out: no write may land in the cache after it is wiped.
    private var isStopped = false
    private var isRunning = false
    /// Work requested while the runner was busy (true: pull too); the runner picks it up before it stops.
    private var requestedPull: Bool?

    init(householdID: UUID, context: ModelContext, client: SyncClient,
         today: @escaping @Sendable () -> CalendarDay = { CalendarDay(Date()) }) {
        self.householdID = householdID
        self.context = context
        self.client = client
        self.today = today
        removeOtherHouseholds()
        pendingCount = pendingChanges().count
    }

    static func persistentContainer() throws -> ModelContainer {
        try ModelContainer(for: schema)
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Removes everything cached on this device, queued changes included. Called on sign-out so the next
    /// person to sign in never sees another household's week or lists.
    static func clearCache(in context: ModelContext) throws {
        try context.delete(model: CachedPlan.self)
        try context.delete(model: CachedNight.self)
        try context.delete(model: CachedListItem.self)
        try context.delete(model: CachedItem.self)
        try context.delete(model: PendingChange.self)
        try context.delete(model: CachedReminders.self)
        try context.delete(model: NotificationRecord.self)
        try context.save()
    }

    /// Syncs, then keeps syncing on server changes and when the network comes back, until cancelled.
    func start() async {
        await sync()
        let client = client
        let household = householdID
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in client.listChanges(household) { await self.sync() } }
            group.addTask { for await _ in client.reconnects() { await self.sync() } }
        }
    }

    /// Replays queued changes, then (if asked) pulls a fresh snapshot. If the runner is busy, the work
    /// is queued for it and this returns at once.
    func sync(pull: Bool = true) async {
        requestedPull = (requestedPull ?? false) || pull
        guard !isRunning, !isStopped else { return }
        isRunning = true
        defer { isRunning = false }
        while let shouldPull = requestedPull {
            requestedPull = nil
            await replayOnce()
            if shouldPull { await pullOnce() }
        }
    }

    /// Stops the service for good (sign-out). Work still in flight finishes without touching the cache.
    func stop() {
        isStopped = true
    }

    /// Whether results that just arrived may still be written.
    private var mayWrite: Bool { !isStopped && !Task.isCancelled }

    func pull() async { await sync(pull: true) }
    func replayPending() async { await sync(pull: false) }

    /// Applies a change to the cache now and queues it for the server.
    func perform(_ change: OfflineChange) async {
        applyLocally(change)
        let sequence = (pendingChanges().map(\.sequence).max() ?? 0) + 1
        if let pending = try? PendingChange(sequence: sequence, householdID: householdID, change: change) {
            context.insert(pending)
        }
        try? context.save()
        pendingCount = pendingChanges().count
        await sync(pull: false)
    }

    /// Adds an item to a list and returns the line's id, usable at once for a check-off.
    @discardableResult
    func addToList(itemID: UUID, list: ListKind, urgency: ListUrgency = .whenever,
                   source: ListItemSource = .manual, note: String? = nil) async -> UUID {
        let lineID = openLine(itemID: itemID, list: list)?.id ?? UUID()
        await perform(.addToList(householdID: householdID, itemID: itemID, list: list, urgency: urgency,
                                 source: source, note: note, lineID: lineID))
        return lineAliases[lineID] ?? lineID
    }

    /// Whether the cached item is a staple, including changes still queued. Nil when it isn't cached.
    func isKeptOnHand(_ itemID: UUID) -> Bool? {
        item(itemID)?.keepOnHand
    }

    /// Device line ids the server merged into existing lines (kept for this session).
    private var lineAliases: [UUID: UUID] = [:]

    // MARK: - Runner steps

    private func replayOnce() async {
        let pending = pendingChanges()
        guard !pending.isEmpty else {
            isOffline = false
            return
        }
        let entries = pending.compactMap { stored in
            stored.change.map { OfflineReplay.Entry(sequence: stored.sequence, change: $0, attempts: stored.attempts) }
        }
        let client = client
        let report = await OfflineReplay.replay(entries) { change in
            do {
                if let existing = try await client.send(change) { return .merged(into: existing) }
                return .sent
            } catch {
                return OfflineReplay.classify(error)
            }
        }
        guard mayWrite else { return }

        let finished = Set(report.sent + report.rejected)
        for stored in pending {
            if finished.contains(stored.sequence) || stored.change == nil {
                context.delete(stored)
            } else if let rewritten = report.rewritten[stored.sequence] {
                stored.payload = (try? JSONEncoder().encode(rewritten)) ?? stored.payload
            }
        }
        if let failed = report.failedAttempt, let stored = pending.first(where: { $0.sequence == failed }) {
            stored.attempts += 1
        }
        repointLines(report.aliases)
        try? context.save()
        pendingCount = pendingChanges().count
        isOffline = !report.remaining.isEmpty
    }

    private func pullOnce() async {
        do {
            let snapshot = try await client.fetchSnapshot(householdID, today())
            guard mayWrite else { return }
            try replaceCache(with: snapshot)
            // The server hasn't seen queued changes yet, so they stay visible on top of the snapshot.
            for change in pendingChanges().compactMap(\.change) {
                applyLocally(change)
            }
            try context.save()
            lastPulled = .now
        } catch {
            if OfflineReplay.classify(error) == .offline { isOffline = true }
        }
    }

    // MARK: - Cache

    /// Backstop for the sign-out wipe: only this household's data may stay on the device.
    private func removeOtherHouseholds() {
        let household = householdID
        try? context.delete(model: CachedPlan.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: CachedNight.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: CachedListItem.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: CachedItem.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: PendingChange.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: CachedReminders.self, where: #Predicate { $0.householdID != household })
        try? context.delete(model: NotificationRecord.self, where: #Predicate { $0.householdID != household })
        try? context.save()
    }

    private func pendingChanges() -> [PendingChange] {
        let household = householdID
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.householdID == household },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func replaceCache(with snapshot: SyncSnapshot) throws {
        let household = householdID
        try context.delete(model: CachedPlan.self, where: #Predicate { $0.householdID == household })
        try context.delete(model: CachedNight.self, where: #Predicate { $0.householdID == household })
        try context.delete(model: CachedListItem.self, where: #Predicate { $0.householdID == household })
        try context.delete(model: CachedItem.self, where: #Predicate { $0.householdID == household })

        let names = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0.canonicalName) })
        snapshot.plan.map { context.insert(CachedPlan($0)) }
        snapshot.nights.forEach { context.insert(CachedNight($0, householdID: household)) }
        snapshot.items.forEach { context.insert(CachedItem($0)) }
        for row in snapshot.listItems {
            context.insert(CachedListItem(
                id: row.id, householdID: household, itemID: row.itemID, itemName: names[row.itemID] ?? "Item",
                list: row.list, urgency: row.urgency, source: row.source, note: row.note, checkedAt: row.checkedAt,
                quantity: row.quantity
            ))
        }
    }

    /// After a server merge, the device's line becomes the existing one.
    private func repointLines(_ aliases: [UUID: UUID]) {
        for (deviceLine, existing) in aliases {
            lineAliases[deviceLine] = existing
            guard let line = listLine(deviceLine) else { continue }
            if listLine(existing) == nil {
                line.id = existing
            } else {
                context.delete(line)
            }
        }
    }

    private func applyLocally(_ change: OfflineChange) {
        switch change {
        case .setChecked(let listItemID, let checked):
            guard let line = listLine(lineAliases[listItemID] ?? listItemID) else { return }
            line.checkedAt = checked ? (line.checkedAt ?? .now) : nil

        case .setStock(let itemID, let state):
            guard let item = item(itemID) else { return }
            item.stockState = state
            item.keepOnHand = state != nil

        case .removeFromList(let listItemID):
            if let line = listLine(lineAliases[listItemID] ?? listItemID) { context.delete(line) }

        case .addToList(let household, let itemID, let list, let urgency, let source, let note, let lineID):
            // Mirrors add_to_list: merge into the item's open line on that list; urgency only goes up.
            if let open = openLine(itemID: itemID, list: list) {
                if urgency == .tonight { open.urgency = .tonight }
                if open.note == nil { open.note = note }
            } else {
                context.insert(CachedListItem(
                    id: lineID, householdID: household, itemID: itemID, itemName: item(itemID)?.name ?? "Item",
                    list: list, urgency: urgency, source: source, note: note, checkedAt: nil
                ))
            }
        }
    }

    private func openLine(itemID: UUID, list: ListKind) -> CachedListItem? {
        let listRaw = list.rawValue
        return try? context.fetch(FetchDescriptor<CachedListItem>(predicate: #Predicate {
            $0.itemID == itemID && $0.listRaw == listRaw && $0.checkedAt == nil
        })).first
    }

    private func listLine(_ id: UUID) -> CachedListItem? {
        try? context.fetch(FetchDescriptor<CachedListItem>(predicate: #Predicate { $0.id == id })).first
    }

    private func item(_ id: UUID) -> CachedItem? {
        try? context.fetch(FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })).first
    }
}
