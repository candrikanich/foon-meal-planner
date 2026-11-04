import Foundation

/// Runs the household's AI queue on this device. A capable device runs a job it submits straight away, and claims the family's
/// waiting jobs when asked (app launch, back in the foreground, and a background refresh on iPhone). A device that can't run
/// the model only submits. Nothing here throws: offline, refused or failed all leave the non-AI result that's already showing.
struct AIJobRunner: Sendable {
    var client: AIJobClient
    var ai: AIService
    var handlers: [AIJobKind: AIJobHandler] = AIJobKind.handlers

    /// What this device can run, named in every claim.
    var kinds: [AIJobKind] { AIJobKind.allCases.filter { handlers[$0] != nil } }

    /// Queues the job and, if this device can run the model, claims and runs it now. The job as this device last saw it, or
    /// nil if it couldn't be queued (offline, say).
    func submit(_ request: AIJobRequest, householdID: UUID) async -> AIJob? {
        guard let job = try? await client.submit(householdID, request) else { return nil }
        guard ai.canRun, let claimed = try? await client.claim(kinds, job.id) else { return job }
        return await run(claimed)
    }

    /// Claims and runs the family's waiting jobs, one at a time, up to `limit`. How many it finished, done or failed.
    func drain(limit: Int) async -> Int {
        var finished = 0
        for _ in 0..<limit {
            guard ai.canRun, !Task.isCancelled, let job = try? await client.claim(kinds, nil) else { break }
            if await run(job).status != .claimed { finished += 1 }
        }
        return finished
    }

    /// A claimed job, run and finished. Still claimed when the model went away, or when finishing was refused (the lease
    /// lapsed and someone else holds it now), so it's theirs to finish.
    private func run(_ job: AIJob) async -> AIJob {
        let outcome: AIJobOutcome
        if let kind = job.kind, let handler = handlers[kind] {
            outcome = await handler(job.payload, ai)
        } else {
            outcome = .failed("unknown kind")
        }
        switch outcome {
        case .done(let result): return (try? await client.complete(job.id, result)) ?? job
        case .failed(let reason): return (try? await client.fail(job.id, reason)) ?? job
        case .unavailable: return job
        }
    }
}
