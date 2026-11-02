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
    /// Dishes made for ideas (idea → dish) that aren't linked yet. Here rather than on the idea's screen, so closing it
    /// after a failed link and coming back still retries the same dish.
    private(set) var madeDishes: [UUID: UUID] = [:]

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

    func rememberDish(_ mealID: UUID, for requestID: UUID) {
        madeDishes[requestID] = mealID
    }

    /// A dish that's been deleted can't be linked, so an idea remembering it goes back to making a new one.
    func dishDeleted(_ mealID: UUID) async {
        madeDishes = madeDishes.filter { $0.value != mealID }
        await load()
    }

    /// The idea as it is now, before saving it as a dish. Ideas have no realtime, so another phone may have got there
    /// first. Nil when it has a dish now, or has gone.
    func latestToSave(_ request: DinnerRequest) async -> DinnerRequest? {
        errorMessage = nil
        await load()
        guard errorMessage == nil else {
            // Offline: go on with what's here. Saving says so if it fails, and the server refuses a second dish.
            errorMessage = nil
            return request
        }
        guard let latest = requests.first(where: { $0.id == request.id }), latest.mealID == nil else {
            madeDishes[request.id] = nil
            return nil
        }
        return latest
    }

    /// Points an idea at the dish made for it. Failing, the dish stays remembered for the retry.
    @discardableResult
    func linkDish(_ mealID: UUID, to requestID: UUID) async -> Bool {
        rememberDish(mealID, for: requestID)
        guard await update(requestID, RequestUpdate(linkMealID: mealID)) else {
            // Another phone may have got there first: show its dish, and don't retry one that would only be refused.
            let refusal = errorMessage
            await load()
            errorMessage = refusal
            let linked = requests.first(where: { $0.id == requestID })?.mealID
            // Gone means the dish went on another phone, or the idea did. Either way a retry would only be refused again.
            if (linked != nil && linked != mealID) || refusal == Self.message(for: .update, code: "P0002") {
                madeDishes[requestID] = nil
            }
            return false
        }
        madeDishes[requestID] = nil
        return true
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
        case (.update, "FD014"):
            String(localized: "Someone already saved this idea as a dish. The one you just made is still in your library.")
        case (.update, "P0002"): String(localized: "That's not here anymore. Pull down on Ideas to refresh.")
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
