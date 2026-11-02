import Foundation
import Observation
import Supabase

/// Tonight's poll. Refreshed while This Week is on screen: nothing tells a phone about a vote until server push (#40).
@Observable
@MainActor
final class PollStore {
    private(set) var poll: TonightPoll?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// Bumped per load, so an older load that finishes last can't bring back a vote someone just changed.
    private var loadGeneration = 0

    private let client: PollClient

    init(client: PollClient) {
        self.client = client
    }

    func poll(for nightID: UUID?) -> TonightPoll? {
        poll?.nightID == nightID ? poll : nil
    }

    /// A failed refresh keeps what's on screen; the next one will catch up, and a vote says for itself whether it was refused.
    func load(nightID: UUID) async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let latest = try await client.latest(nightID)
            if generation == loadGeneration { poll = latest }
        } catch {}
    }

    /// Returns whether it started. Refused because someone else's just started, that one's on screen after the reload.
    func start(nightID: UUID, minutes: Int, choices: [PollChoice]) async -> Bool {
        await write(nightID: nightID) { [client] in try await client.start(nightID, minutes, choices) }
    }

    func vote(_ poll: TonightPoll, memberID: UUID, option: Int) async {
        await write(nightID: poll.nightID) { [client] in try await client.vote(poll.id, memberID, option) }
    }

    func close(_ poll: TonightPoll) async {
        await write(nightID: poll.nightID) { [client] in try await client.close(poll.id) }
    }

    func clearError() {
        errorMessage = nil
    }

    func note(_ message: String) {
        errorMessage = message
    }

    @discardableResult
    private func write(nightID: UUID, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        var succeeded = true
        do {
            try await work()
            errorMessage = nil
        } catch {
            succeeded = false
            errorMessage = Self.message(for: (error as? PostgrestError)?.code)
        }
        await load(nightID: nightID)
        return succeeded
    }

    static func message(for code: String?) -> String {
        switch code {
        case "FD004": String(localized: "They eat separately, so they don't vote.")
        case "FD017": String(localized: "Tonight's dinner is already logged.")
        case "FD018": String(localized: "Someone just started a poll for tonight.")
        case "FD019": String(localized: "They're marked out tonight, and the vote is for whoever's home.")
        case "FD020": String(localized: "This poll has closed.")
        case "22023": String(localized: "Something on this poll has changed. Close this and try again.")
        default: String(localized: "Couldn't save that. Check your connection and try again.")
        }
    }
}
