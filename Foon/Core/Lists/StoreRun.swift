import Foundation
import Supabase

/// "Heading to the store" (docs/spec.md → Heading to the store, #51): someone tells the family they're shopping, and what's
/// added in the next 10 minutes is marked in store mode. Any adult starts one; the server keeps one open at a time.
struct StoreRun: Identifiable, Equatable, Sendable, Decodable {
    let id: UUID
    let startedBy: UUID?
    let startedAt: Date
    let endsAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case startedBy = "started_by"
        case startedAt = "started_at"
        case endsAt = "ends_at"
    }

    func isOpen(at now: Date) -> Bool { endsAt > now }

    /// Store mode marks what came in during a run for a couple of hours: long enough for the trip it was for, and an old
    /// run's lines aren't news on the next one.
    func isRecent(at now: Date) -> Bool { now.timeIntervalSince(startedAt) < 2 * 60 * 60 }

    /// Whole minutes left, rounded up, so the last seconds still read "1 min left" rather than "0".
    func minutesLeft(at now: Date) -> Int {
        max(0, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// A line put on the list while the run was open, by anyone: what the family added for whoever's shopping.
    func added(_ createdAt: Date?) -> Bool {
        guard let createdAt else { return false }
        return createdAt >= startedAt && createdAt <= endsAt
    }

    /// Adults start one; kids add to the list.
    static func canStart(_ member: Member?) -> Bool {
        guard let member else { return false }
        return member.ageGroup == .adult && member.status != .removed
    }
}

extension ListEntry {
    /// Marked "Just added" in store mode: this row, or the other line it stands for, went on during the run.
    func justAdded(during run: StoreRun?, now: Date = .now) -> Bool {
        guard let run, run.isRecent(at: now) else { return false }
        return run.added(createdAt) || folded.contains { run.added($0.createdAt) }
    }
}

struct StoreRunClient: Sendable {
    /// The household's latest run, open or not.
    var latest: @Sendable (_ householdID: UUID) async throws -> StoreRun?
    /// Starts one (`start_store_run`), or hands back the one already open.
    var start: @Sendable (_ householdID: UUID) async throws -> StoreRun
}

extension StoreRunClient {
    static func live(_ client: SupabaseClient) -> StoreRunClient {
        StoreRunClient(
            latest: { householdID in
                let runs: [StoreRun] = try await client.from("store_runs")
                    .select("id, started_by, started_at, ends_at")
                    .eq("household_id", value: householdID)
                    .order("ends_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                return runs.first
            },
            start: { householdID in
                try await client.rpc("start_store_run", params: ["target_household": householdID.uuidString])
                    .execute()
                    .value
            }
        )
    }

    static let preview = StoreRunClient(latest: { _ in nil }, start: { _ in
        StoreRun(id: UUID(), startedBy: Member.sampleFamily.first?.id, startedAt: .now, endsAt: .now.addingTimeInterval(600))
    })

    /// The environment's default: fails loudly if a screen forgets the live client.
    static let unconfigured = StoreRunClient(latest: { _ in
        assertionFailure("Set \\.storeRunClient at the app root")
        return nil
    }, start: { _ in
        assertionFailure("Set \\.storeRunClient at the app root")
        throw LibraryClientError.notAllowed
    })
}
