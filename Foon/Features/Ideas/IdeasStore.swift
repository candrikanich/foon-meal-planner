import Foundation
import Observation
import Supabase

/// The idea inbox's state: the family's open requests and what can be done with them (docs/spec.md → Idea inbox).
@Observable @MainActor
final class IdeasStore {
    private(set) var requests: [DinnerRequest] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Requests with a write in flight, so their buttons don't fire twice.
    private(set) var saving: Set<UUID> = []

    let householdID: UUID
    private let client: IdeasClient
    private var loadGeneration = 0

    init(householdID: UUID, client: IdeasClient) {
        self.householdID = householdID
        self.client = client
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let loaded = try await client.requests(householdID)
            guard generation == loadGeneration else { return }
            requests = loaded
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !(error is CancellationError) else { return }
            errorMessage = String(localized: "Couldn't load the ideas. Check your connection and try again.")
        }
    }

    /// True while an idea is being sent, so a double tap doesn't send it twice.
    private(set) var isSending = false

    /// I want...: returns whether it was sent.
    @discardableResult
    func make(_ request: NewRequest) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await client.make(householdID, request)
            await load()
            return true
        } catch {
            errorMessage = Self.message(for: .make, code: (error as? PostgrestError)?.code)
            return false
        }
    }

    @discardableResult
    func toggleMeToo(_ requestID: UUID, memberID: UUID) async -> Bool {
        await write(requestID, .meToo) { [client] in _ = try await client.toggleMeToo(requestID, memberID) }
    }

    @discardableResult
    func update(_ requestID: UUID, _ update: RequestUpdate) async -> Bool {
        await write(requestID, .update) { [client] in try await client.update(requestID, update) }
    }

    enum Action: Sendable { case make, meToo, update }

    /// Each refusal in words for what was tried (the server's codes mean different things per call).
    static func message(for action: Action, code: String?) -> String {
        switch (action, code) {
        case (.make, "42501"), (.meToo, "42501"):
            String(localized: "You can do that for yourself, or for someone without their own account.")
        case (.make, "22023"): String(localized: "That night has already passed.")
        case (.make, "23514"):
            String(localized: "Ask for a dish, a name, or a link (names up to 80 characters, notes up to 200).")
        case (.meToo, "22023"): String(localized: "It's already your idea.")
        case (.update, "42501"): String(localized: "Only planners can do that with someone else's idea.")
        case (.update, "22023"): String(localized: "Pick a night from today on to plan it.")
        case (.update, "23514"): String(localized: "Notes need 200 characters or fewer.")
        case (.make, _): String(localized: "Couldn't send the idea. Check your connection and try again.")
        default: String(localized: "Couldn't save that. Check your connection and try again.")
        }
    }

    /// After Build my week, Fill, or a swap: requests that landed are marked planned there (`requestNights`: the nights
    /// Build placed a dish on as a request, meal → night), and planned ones whose night no longer has their dish go
    /// back to open, sitting that week out so a Rebuild doesn't bring them straight back. One reload at the end; the
    /// first failure is kept. After an undo, a request the undone swap sent back goes with its dish (`undoneNight`).
    func sync(with week: Week?, today: CalendarDay, requestNights: [UUID: UUID] = [:], away: [AwayDates] = [],
              undoneNight: UUID? = nil) async {
        guard let week else { return }
        var failure: String?
        let landing = requestNights.merging(undoneNight.map { RequestBoard.sentBack(requests, night: $0, in: week) } ?? [:]) { first, _ in first }
        let changes = RequestBoard.landed(requests, nights: week.nights, today: today, requestNights: landing, away: away)
            .map { ($0.requestID, RequestUpdate(status: .planned, nightID: $0.nightID)) }
            + RequestBoard.unlanded(requests, nights: week.nights)
                .map { ($0, RequestUpdate(status: .open, skipWeek: week.start)) }
        guard !changes.isEmpty else { return }
        for (id, change) in changes {
            do {
                try await client.update(id, change)
            } catch {
                failure = failure ?? Self.message(for: .update, code: (error as? PostgrestError)?.code)
            }
        }
        await load()
        if let failure { errorMessage = failure }
    }

    func clearError() {
        errorMessage = nil
    }

    private func write(_ requestID: UUID, _ action: Action, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        guard !saving.contains(requestID) else { return false }
        saving.insert(requestID)
        defer { saving.remove(requestID) }
        do {
            try await work()
        } catch {
            errorMessage = Self.message(for: action, code: (error as? PostgrestError)?.code)
            return false
        }
        await load()
        return true
    }
}
