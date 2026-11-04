import Foundation

/// The kinds of job the household queue runs (`ai_jobs.kind`). A device claims only the kinds it has a handler for, so an
/// older app never takes a job it can't run.
enum AIJobKind: String, Codable, CaseIterable, Sendable {
    /// Hands back its payload without the model. No feature submits it: it proves the queue end to end (a job put in by hand
    /// on staging comes back done).
    case echo
    /// Captured recipe text (a photo's, a PDF's or a post's caption) structured into a recipe (#59).
    case recipe
}

enum AIJobStatus: String, Codable, Sendable {
    case queued, claimed, done, failed, expired
}

/// One job in the household's queue.
struct AIJob: Equatable, Identifiable, Sendable {
    let id: UUID
    let householdID: UUID
    /// Nil for a kind a newer app added.
    let kind: AIJobKind?
    /// A JSON object, written only from an `AIJobRequest`.
    let payload: Data
    let status: AIJobStatus
    /// A JSON object once it's done.
    let result: Data?
    let error: String?
    let updatedAt: Date

    func with(status: AIJobStatus, result: Data? = nil, error: String? = nil) -> AIJob {
        AIJob(id: id, householdID: householdID, kind: kind, payload: payload, status: status,
              result: result ?? self.result, error: error ?? self.error, updatedAt: .now)
    }

    func decodedResult<Result: Decodable>(_ type: Result.Type) throws -> Result? {
        try result.map { try JSONDecoder().decode(type, from: $0) }
    }

    var summary: AIJobSummary {
        AIJobSummary(id: id, kind: kind, status: status, result: result, updatedAt: updatedAt)
    }
}

/// A job as the screens need it: where it's got to and its result. Never its payload, which only the device running it reads.
struct AIJobSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: AIJobKind?
    let status: AIJobStatus
    let result: Data?
    let updatedAt: Date

    var isOpen: Bool { status == .queued || status == .claimed }

    func decodedResult<Result: Decodable>(_ type: Result.Type) -> Result? {
        result.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// What a device asks the household's capable devices to do: one case per kind, each with a payload struct.
///
/// Payloads leave this device for the household's queue, so they never carry allergy data (CLAUDE.md rule 4). That holds by
/// construction: the queue only takes an `AIJobRequest`, never raw JSON, and no payload struct has a field for allergies or
/// for a member. Allergy checks run on whichever device shows the result, as they do everywhere else.
/// `AIJobPayloadTests` checks every kind.
enum AIJobRequest: Equatable, Sendable {
    case echo(EchoPayload)
    case recipe(RecipeJobPayload)

    var kind: AIJobKind {
        switch self {
        case .echo: .echo
        case .recipe: .recipe
        }
    }

    func payload() throws -> Data {
        switch self {
        case .echo(let payload): try JSONEncoder().encode(payload)
        case .recipe(let payload): try JSONEncoder().encode(payload)
        }
    }
}

struct EchoPayload: Codable, Equatable, Sendable {
    let text: String
}

/// How running one job went on this device.
enum AIJobOutcome: Equatable, Sendable {
    /// The result, a JSON object, for everyone.
    case done(Data)
    /// Timed out, the model failed, or the payload didn't read. The job ends; the non-AI result stays.
    case failed(String)
    /// The model went away after the claim (it's downloading, say). Nothing's written: the lease lapses and another
    /// capable device can take the job.
    case unavailable
}

typealias AIJobHandler = @Sendable (_ payload: Data, _ ai: AIService) async -> AIJobOutcome

extension AIJobKind {
    /// What runs each kind.
    static let handlers: [AIJobKind: AIJobHandler] = [
        .echo: { payload, _ in
            guard let echo = try? JSONDecoder().decode(EchoPayload.self, from: payload),
                  let result = try? JSONEncoder().encode(echo) else { return .failed("unreadable payload") }
            return .done(result)
        },
        .recipe: RecipeStructuring.handle
    ]
}

extension AIOutcome {
    /// For a handler: a model answer becomes the job's result; no answer ends the job, except a model that went away.
    func jobOutcome(_ encode: (Output) throws -> Data) -> AIJobOutcome {
        switch self {
        case .done(let output): (try? encode(output)).map(AIJobOutcome.done) ?? .failed("unencodable result")
        case .unavailable: .unavailable
        case .timedOut: .failed("timed out")
        case .failed: .failed("model failed")
        }
    }
}
