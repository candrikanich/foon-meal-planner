import Foundation
import FoundationModels
import Synchronization

/// Whether Apple's on-device model can run here: an eligible device, Apple Intelligence on, and the model downloaded.
enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        /// Still downloading, or the system's busy. It may be ready next time.
        case modelNotReady
        case other
    }

    init(_ system: SystemLanguageModel.Availability) {
        switch system {
        case .available: self = .available
        case .unavailable(.deviceNotEligible): self = .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): self = .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady): self = .unavailable(.modelNotReady)
        @unknown default: self = .unavailable(.other)
        }
    }
}

/// How an AI call ended. Anything but `done` means the caller keeps its non-AI result.
enum AIOutcome<Output: Sendable>: Sendable {
    case done(Output)
    case unavailable
    case timedOut
    case failed
}

extension AIOutcome: Equatable where Output: Equatable {}

/// The on-device model, as closures, so tests stub it without Apple Intelligence (CI and the simulator usually lack it).
/// A helper only: every caller has a non-AI path, and a call never throws, crashes or outlasts its timeout.
struct AIService: Sendable {
    var availability: @Sendable () -> AIAvailability
    /// One guided-generation call in a fresh session: the model's answer, shaped by the schema.
    var respond: @Sendable (_ instructions: String, _ prompt: String, _ schema: GenerationSchema) async throws
        -> GeneratedContent
    /// Long enough for a few seconds of on-device generation with room to spare, short enough that nobody's left waiting.
    var timeout: Duration = .seconds(30)

    var canRun: Bool { availability() == .available }

    func generate<Output: Generable & Sendable>(_ type: Output.Type, instructions: String,
                                                prompt: String) async -> AIOutcome<Output> {
        guard canRun else { return .unavailable }
        let respond = respond
        let answer = await Self.firstOf(timeout: timeout) {
            try await respond(instructions, prompt, Output.generationSchema)
        }
        switch answer {
        case nil:
            return .timedOut
        case .failure:
            return .failed
        case .success(let content):
            guard let output = try? Output(content) else { return .failed }
            return .done(output)
        }
    }

    /// The work's result, or nil once the timeout passes or the caller is cancelled, whichever is first. The work runs in a
    /// task of its own and is cancelled when it loses, but it's never waited on: a model that ignores cancellation can't
    /// hold the caller.
    private static func firstOf<Value: Sendable>(
        timeout: Duration, _ work: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, any Error>? {
        let waiting = Mutex<CheckedContinuation<Result<Value, any Error>?, Never>?>(nil)
        let tasks = Mutex<[Task<Void, Never>]>([])
        let finish: @Sendable (Result<Value, any Error>?) -> Void = { value in
            waiting.withLock { $0.take() }?.resume(returning: value)
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.withLock { $0 = continuation }
                let worker = Task {
                    do { finish(.success(try await work())) } catch { finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    finish(nil)
                }
                tasks.withLock { $0 = [worker, timer] }
                if Task.isCancelled { finish(nil) }
            }
        } onCancel: {
            finish(nil)
        }
        tasks.withLock { $0 }.forEach { $0.cancel() }
        return value
    }
}

extension AIService {
    static let live = AIService(
        availability: { AIAvailability(SystemLanguageModel.default.availability) },
        respond: { instructions, prompt, schema in
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt, schema: schema).content
        }
    )

    /// Previews and tests that never reach the model.
    static let none = AIService(availability: { .unavailable(.deviceNotEligible) },
                                respond: { _, _, _ in throw CancellationError() })
}
