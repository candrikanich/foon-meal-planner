import Foundation
import Observation

/// The household's AI queue for the screens: runs the family's waiting jobs when this device can, and holds the recent jobs,
/// results included, as Supabase last had them.
@MainActor
@Observable
final class AIQueueStore {
    /// How many waiting jobs one foreground visit takes on. Each is seconds of on-device work, so a backlog clears over a few
    /// opens rather than holding the model for minutes.
    static let foregroundLimit = 5

    private(set) var jobs: [AIJob] = []
    let householdID: UUID
    private let runner: AIJobRunner
    private var draining = false

    init(householdID: UUID, runner: AIJobRunner) {
        self.householdID = householdID
        self.runner = runner
    }

    /// Launch and back in the foreground: claim and run what's waiting (one pass at a time), then load what's finished,
    /// which is how a result from another device shows up here.
    func refresh() async {
        if !draining {
            draining = true
            _ = await runner.drain(limit: Self.foregroundLimit)
            draining = false
        }
        await load()
    }

    /// The job as it stands after this device has had its go. Nil when it couldn't be queued: the non-AI result stands.
    func submit(_ request: AIJobRequest) async -> AIJob? {
        guard let job = await runner.submit(request, householdID: householdID) else { return nil }
        jobs = [job] + jobs.filter { $0.id != job.id }
        return job
    }

    private func load() async {
        // Offline keeps what was last loaded.
        guard let recent = try? await runner.client.recent(householdID) else { return }
        jobs = recent
    }
}
