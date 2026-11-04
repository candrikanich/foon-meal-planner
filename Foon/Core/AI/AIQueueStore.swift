import Foundation
import Observation

/// The household's AI queue for the screens: runs the family's waiting jobs when this device can, runs its own straight away,
/// and follows the jobs this device is waiting on until they finish.
@MainActor
@Observable
final class AIQueueStore {
    /// How many waiting jobs one foreground visit takes on. Each is seconds of on-device work, so a backlog clears over a few
    /// opens rather than holding the model for minutes.
    static let foregroundLimit = 5
    /// A job expires 3 days after it's submitted; an hour on, one never seen finished is gone (pruned, or never visible).
    static let watchLimit: TimeInterval = 3 * 86_400 + 3_600

    enum ApplyOutcome: Sendable {
        /// Applied, or nothing to apply it to: either way the watch is done.
        case finished
        /// Not now (the library hasn't loaded, or the save didn't go through): next refresh.
        case retry
    }

    /// The jobs this device submitted or is waiting on, as last seen.
    private(set) var jobs: [UUID: AIJobSummary] = [:]
    /// Meals saved before their recipe result came, kept across launches.
    private(set) var watches: [RecipeWatch]
    /// Puts a finished recipe into its meal. Set by whoever holds the library.
    var applyRecipe: (@MainActor (RecipeWatch, StructuredRecipe) async -> ApplyOutcome)?

    let householdID: UUID
    private let runner: AIJobRunner
    private let shelf: AIWatchShelf
    private let now: @Sendable () -> Date
    private var draining = false
    private var ownRuns: [UUID: Task<Void, Never>] = [:]

    init(householdID: UUID, runner: AIJobRunner, shelf: AIWatchShelf = .memory(),
         now: @escaping @Sendable () -> Date = { .now }) {
        self.householdID = householdID
        self.runner = runner
        self.shelf = shelf
        self.now = now
        watches = shelf.load()
    }

    /// Launch and back in the foreground: claim and run what's waiting (one pass at a time), then load the jobs this device
    /// is waiting on, which is how a result from another device shows up here.
    func refresh() async {
        if !draining {
            draining = true
            _ = await runner.drain(limit: Self.foregroundLimit)
            draining = false
        }
        await load()
        await settle()
    }

    /// Queues the job and returns its id at once; nil when it couldn't be queued, and the non-AI result stands. A capable
    /// device runs it in a task of the store's own, so closing the screen that asked doesn't cancel the model.
    func submit(_ request: AIJobRequest) async -> UUID? {
        guard let job = await runner.queue(request, householdID: householdID) else { return nil }
        jobs[job.id] = job.summary
        if runner.ai.canRun {
            ownRuns[job.id] = Task {
                let finished = await runner.runOwn(job)
                jobs[job.id] = finished.summary
                ownRuns[job.id] = nil
                await settle()
            }
        }
        return job.id
    }

    /// Whether this device runs its own jobs, or leaves them for a family device.
    var runsHere: Bool { runner.ai.canRun }

    /// Queued or being run, here or on a family device.
    func isProcessing(_ jobID: UUID) -> Bool {
        jobs[jobID]?.isOpen == true || watches.contains { $0.jobID == jobID }
    }

    func isProcessing(meal: UUID) -> Bool {
        watches.contains { $0.mealID == meal }
    }

    /// The result, once it's done.
    func recipe(for jobID: UUID) -> StructuredRecipe? {
        guard let job = jobs[jobID], job.status == .done else { return nil }
        return job.decodedResult(StructuredRecipe.self)
    }

    /// A meal was saved from a draft whose job hasn't finished: its result goes into the meal when it comes. A job that's
    /// already finished needs nothing: the draft had its result, or there's none.
    func watch(_ jobID: UUID, meal: UUID, baseline: RecipeBaseline) {
        guard jobs[jobID]?.isOpen == true else { return }
        watches.append(RecipeWatch(jobID: jobID, mealID: meal, baseline: baseline, submittedAt: now()))
        shelf.save(watches)
    }

    /// Waits for the jobs this device is running itself.
    func ownRunsFinished() async {
        while let run = ownRuns.values.first { await run.value }
    }

    private func load() async {
        let waiting = Set(watches.map(\.jobID)).union(jobs.values.filter(\.isOpen).map(\.id)).subtracting(ownRuns.keys)
        // Offline keeps what was last loaded.
        guard !waiting.isEmpty, let loaded = try? await runner.client.statuses(Array(waiting)) else { return }
        for job in loaded { jobs[job.id] = job }
    }

    /// Each watched job that's finished goes into its meal, or, failed or expired, just ends: the plain read stays.
    private func settle() async {
        for watch in watches {
            switch jobs[watch.jobID]?.status {
            case .done:
                // Nobody to apply it yet (the screens are still starting): next time.
                guard let applyRecipe else { continue }
                if let recipe = recipe(for: watch.jobID) {
                    guard await applyRecipe(watch, recipe) == .finished else { continue }
                }
            case .failed, .expired:
                break
            case .queued, .claimed, nil:
                guard now().timeIntervalSince(watch.submittedAt) > Self.watchLimit else { continue }
            }
            watches.removeAll { $0 == watch }
            shelf.save(watches)
        }
    }
}

/// A meal waiting for its recipe result.
struct RecipeWatch: Codable, Equatable, Sendable {
    let jobID: UUID
    let mealID: UUID
    let baseline: RecipeBaseline
    let submittedAt: Date
}

/// Where watches are kept between launches: ids, dates and digests, never recipe text.
struct AIWatchShelf: Sendable {
    var load: @Sendable () -> [RecipeWatch]
    var save: @Sendable ([RecipeWatch]) -> Void
}

extension AIWatchShelf {
    static func live(householdID: UUID, defaults: UserDefaults = .standard) -> AIWatchShelf {
        let key = "ai.recipeWatches.\(householdID.uuidString)"
        // UserDefaults is thread-safe; it just isn't marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        return AIWatchShelf(
            load: { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecipeWatch].self, from: $0) } ?? [] },
            save: { watches in
                if watches.isEmpty {
                    defaults.removeObject(forKey: key)
                } else if let data = try? JSONEncoder().encode(watches) {
                    defaults.set(data, forKey: key)
                }
            }
        )
    }

    static func memory() -> AIWatchShelf {
        let kept = Kept()
        return AIWatchShelf(load: { kept.watches }, save: { kept.watches = $0 })
    }

    private final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [RecipeWatch] = []

        var watches: [RecipeWatch] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
