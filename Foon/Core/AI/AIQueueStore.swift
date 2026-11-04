import Foundation
import Observation

/// The household's AI for the screens. A device that can run the model tidies a captured recipe itself and never sends it;
/// one that can't queues the recipe for a family device, and only once a planner saves the dish. The store also runs the
/// family's waiting jobs when it can, and follows each saved dish until its tidy-up lands or ends.
@MainActor
@Observable
final class AIQueueStore {
    /// How many waiting jobs one foreground visit takes on. Each is seconds of on-device work, so a backlog clears over a few
    /// opens rather than holding the model for minutes.
    static let foregroundLimit = 5
    /// A job expires 3 days after it's submitted; an hour on, a watch goes whatever state it's in, so none waits forever.
    static let watchLimit: TimeInterval = 3 * 86_400 + 3_600

    enum ApplyOutcome: Equatable, Sendable {
        /// The meal took the result.
        case applied
        /// Nothing to apply it to, nothing left to change, or the server refused: the watch is done.
        case finished
        /// Not now (offline, or the library hasn't loaded): next refresh.
        case retry
    }

    /// Queued jobs this device is waiting on, as last seen.
    private(set) var jobs: [UUID: AIJobSummary] = [:]
    /// Saved dishes waiting for their tidy-up, kept across launches.
    private(set) var watches: [RecipeWatch]
    /// Results of tidy-ups run on this device, by the token `tidyHere` handed out.
    private(set) var tidied: [UUID: StructuredRecipe] = [:]
    /// Puts a finished recipe into its meal. Set by whoever holds the library.
    var applyRecipe: (@MainActor (RecipeWatch, StructuredRecipe) async -> ApplyOutcome)?
    /// Recipe jobs are claimed only by a planner's device (the server holds the same rule): a result goes into a dish.
    var isPlanner = false

    let householdID: UUID
    private let runner: AIJobRunner
    private let shelf: AIWatchShelf
    private let now: @Sendable () -> Date
    private var draining = false
    private var settling = false
    private var settleAgain = false
    private var tidying: [UUID: Task<Void, Never>] = [:]

    init(householdID: UUID, runner: AIJobRunner, shelf: AIWatchShelf = .memory(),
         now: @escaping @Sendable () -> Date = { .now }) {
        self.householdID = householdID
        self.runner = runner
        self.shelf = shelf
        self.now = now
        watches = shelf.load()
    }

    /// Whether this device runs the model itself.
    var runsHere: Bool { runner.ai.canRun }

    /// Launch and back in the foreground: claim and run what's waiting (one pass at a time), then load the jobs this device
    /// is waiting on, which is how a result from another device shows up here.
    func refresh() async {
        if !draining {
            draining = true
            let kinds = runner.kinds.filter { $0 != .recipe || isPlanner }
            _ = await runner.drain(limit: Self.foregroundLimit, kinds: kinds)
            draining = false
        }
        await load()
        await settle()
    }

    /// Tidies a captured recipe on this device, in a task of the store's own so closing the screen doesn't stop it. A token
    /// for its result; nil when this device can't run the model (then nothing happens until the dish is saved).
    func tidyHere(_ payload: RecipeJobPayload) -> UUID? {
        guard runsHere else { return nil }
        let token = UUID()
        let ai = runner.ai
        tidying[token] = Task {
            if case .done(let recipe) = await RecipeStructuring.structure(payload, ai) { tidied[token] = recipe }
            tidying[token] = nil
            await settle()
        }
        return token
    }

    func isTidying(_ token: UUID) -> Bool { tidying[token] != nil }

    func isProcessing(meal: UUID) -> Bool {
        watches.contains { $0.mealID == meal }
    }

    /// A planner saved a dish from a capture. Whatever of the tidy-up the review screen didn't already take goes into the
    /// dish when it comes: from this device's own run (`token`), or, on a device that can't run the model, from a job queued
    /// now for a family device. `alreadyTaken` is true when the screen merged the result before the save.
    func saved(meal: UUID, baseline: RecipeBaseline, token: UUID?, alreadyTaken: Bool, payload: RecipeJobPayload) async {
        guard !alreadyTaken else { return }
        if let token {
            add(RecipeWatch(source: .here(token), mealID: meal, baseline: baseline, submittedAt: now()))
        } else if !runsHere, let job = await runner.queue(.recipe(payload), householdID: householdID) {
            jobs[job.id] = job.summary
            add(RecipeWatch(source: .job(job.id), mealID: meal, baseline: baseline, submittedAt: now()))
        }
        await settle()
    }

    /// The review screen closed without saving: a run here has nobody waiting on it.
    func forget(_ token: UUID) {
        guard !watches.contains(where: { $0.source == .here(token) }) else { return }
        tidying[token]?.cancel()
        tidying[token] = nil
        tidied[token] = nil
    }

    /// Waits for the tidy-ups running on this device.
    func tidyingFinished() async {
        while let run = tidying.values.first { await run.value }
    }

    private func add(_ watch: RecipeWatch) {
        watches.append(watch)
        shelf.save(watches)
    }

    private func load() async {
        let waiting = watches.compactMap { watch -> UUID? in
            guard case .job(let id) = watch.source, jobs[id]?.isOpen != false else { return nil }
            return id
        }
        // Offline keeps what was last loaded.
        guard !waiting.isEmpty, let loaded = try? await runner.client.statuses(waiting) else { return }
        for job in loaded { jobs[job.id] = job }
    }

    /// Each watched dish whose tidy-up is ready takes it; one that failed, expired or ran out of time just ends: the plain
    /// read stays.
    private func settle() async {
        // One pass at a time, so a watch is never applied twice; a call during a pass gets another pass after it.
        guard !settling else {
            settleAgain = true
            return
        }
        settling = true
        defer { settling = false }
        repeat {
            settleAgain = false
            await settlePass()
        } while settleAgain
    }

    private func settlePass() async {
        for watch in watches {
            if now().timeIntervalSince(watch.submittedAt) <= Self.watchLimit {
                switch result(for: watch) {
                case .waiting:
                    continue
                case .ready(let recipe):
                    // Nobody to apply it yet (the screens are still starting): next time.
                    guard let applyRecipe, await applyRecipe(watch, recipe) != .retry else { continue }
                case .none:
                    break
                }
            }
            watches.removeAll { $0 == watch }
            shelf.save(watches)
        }
    }

    private enum Pending {
        case waiting
        case ready(StructuredRecipe)
        /// Failed, expired, unreadable, or a run here that ended with the app.
        case none
    }

    private func result(for watch: RecipeWatch) -> Pending {
        switch watch.source {
        case .here(let token):
            if let recipe = tidied[token] { return .ready(recipe) }
            return tidying[token] == nil ? .none : .waiting
        case .job(let id):
            guard let job = jobs[id] else { return .waiting }
            switch job.status {
            case .queued, .claimed: return .waiting
            case .failed, .expired: return .none
            case .done: return job.decodedResult(StructuredRecipe.self).map(Pending.ready) ?? .none
            }
        }
    }
}

/// A saved dish waiting for its tidy-up.
struct RecipeWatch: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        /// Run on this device; the token `tidyHere` gave.
        case here(UUID)
        /// Queued for a family device.
        case job(UUID)
    }

    let source: Source
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
