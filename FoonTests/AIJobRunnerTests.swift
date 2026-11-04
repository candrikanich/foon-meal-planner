import Foundation
import Testing
@testable import Foon

/// The household AI queue on a device (#58): a capable device runs its own job straight away and claims the family's; one that
/// can't run the model only submits; whatever goes wrong leaves the non-AI result showing.
struct AIJobRunnerTests {
    private let household = UUID()

    private func runner(_ queue: FakeAIQueue, canRun: Bool = true,
                        handlers: [AIJobKind: AIJobHandler] = AIJobKind.handlers) -> AIJobRunner {
        AIJobRunner(client: queue.client, ai: .stub(canRun: canRun), handlers: handlers)
    }

    @Test func aCapableDeviceRunsItsOwnJobRightAway() async throws {
        let queue = FakeAIQueue()

        let job = try #require(await runner(queue).submit(.echo(EchoPayload(text: "tacos")), householdID: household))

        #expect(job.status == .done)
        #expect(try job.decodedResult(EchoPayload.self) == EchoPayload(text: "tacos"))
        #expect(await queue.claims == [ClaimCall(kinds: [.echo], job: job.id)])
    }

    @Test func aDeviceThatCantRunTheModelOnlySubmits() async throws {
        let queue = FakeAIQueue()

        let job = try #require(await runner(queue, canRun: false).submit(.echo(EchoPayload(text: "tacos")),
                                                                         householdID: household))

        #expect(job.status == .queued)
        #expect(await queue.claims.isEmpty)
        #expect(await runner(queue, canRun: false).drain(limit: 5) == 0)
        #expect(await queue.claims.isEmpty)
    }

    @Test func aCapableDeviceClaimsTheFamilysWaitingJobs() async throws {
        let queue = FakeAIQueue()
        let other = runner(queue, canRun: false)
        _ = await other.submit(.echo(EchoPayload(text: "one")), householdID: household)
        _ = await other.submit(.echo(EchoPayload(text: "two")), householdID: household)

        let finished = await runner(queue).drain(limit: 5)

        #expect(finished == 2)
        #expect(await queue.jobs.allSatisfy { $0.status == .done })
        #expect(await queue.claims.allSatisfy { $0.kinds == [.echo] && $0.job == nil })
    }

    @Test func drainingStopsAtItsLimit() async {
        let queue = FakeAIQueue()
        for text in ["one", "two", "three"] {
            _ = await runner(queue, canRun: false).submit(.echo(EchoPayload(text: text)), householdID: household)
        }

        #expect(await runner(queue).drain(limit: 1) == 1)
        #expect(await queue.jobs.filter { $0.status == .queued }.count == 2)
    }

    @Test func aTimedOutOrFailedRunFailsTheJobAndTheNonAIResultStays() async throws {
        let queue = FakeAIQueue()
        let failing: [AIJobKind: AIJobHandler] = [.echo: { _, _ in .failed("timed out") }]

        let job = try #require(await runner(queue, handlers: failing).submit(.echo(EchoPayload(text: "x")),
                                                                            householdID: household))

        #expect(job.status == .failed)
        #expect(await queue.jobs.first?.error == "timed out")
    }

    @Test func aModelThatWentAwayLeavesTheClaimToLapseForAnotherDevice() async throws {
        let queue = FakeAIQueue()
        let gone: [AIJobKind: AIJobHandler] = [.echo: { _, _ in .unavailable }]

        let job = try #require(await runner(queue, handlers: gone).submit(.echo(EchoPayload(text: "x")),
                                                                         householdID: household))

        #expect(job.status == .claimed)
        #expect(await queue.finishes.isEmpty)
    }

    @Test func offlineSubmittingReturnsNothingAndNeverThrows() async {
        let queue = FakeAIQueue(offline: true)

        #expect(await runner(queue).submit(.echo(EchoPayload(text: "x")), householdID: household) == nil)
        #expect(await runner(queue).drain(limit: 3) == 0)
    }

    @Test func aRefusedCompleteLeavesTheJobToWhoeverHoldsItNow() async throws {
        let queue = FakeAIQueue(refuseFinishing: true)

        let job = try #require(await runner(queue).submit(.echo(EchoPayload(text: "x")), householdID: household))

        #expect(job.status == .claimed)
    }

    @Test func theEchoKindHandsBackItsPayloadWithoutTheModel() async throws {
        let payload = try AIJobRequest.echo(EchoPayload(text: "soup")).payload()
        let handler = try #require(AIJobKind.handlers[.echo])

        let outcome = await handler(payload, .stub(canRun: true))

        guard case .done(let result) = outcome else { Issue.record("expected a result, got \(outcome)"); return }
        #expect(try JSONDecoder().decode(EchoPayload.self, from: result) == EchoPayload(text: "soup"))
    }

    @Test func aPayloadThatDoesntReadIsAFailureNotACrash() async throws {
        let handler = try #require(AIJobKind.handlers[.echo])

        #expect(await handler(Data("{}".utf8), .stub(canRun: true)) == .failed("unreadable payload"))
    }

    @Test func everyKindHasAHandler() {
        #expect(Set(AIJobKind.handlers.keys) == Set(AIJobKind.allCases))
    }
}

/// Payloads leave the device for the household's queue, so allergy data can't be in one (CLAUDE.md rule 4).
struct AIJobPayloadTests {
    /// One request of each kind. The switch stops compiling when a kind is added, so the new one gets checked here too.
    private func sample(_ kind: AIJobKind) -> AIJobRequest {
        switch kind {
        case .echo: .echo(EchoPayload(text: "Grandma's chili"))
        }
    }

    @Test(arguments: AIJobKind.allCases)
    func noPayloadHasAFieldThatCanHoldAllergies(kind: AIJobKind) throws {
        let request = sample(kind)
        #expect(request.kind == kind)
        #expect(!Self.holdsAllergies(Mirror(reflecting: request)))

        let object = try JSONSerialization.jsonObject(with: request.payload())
        #expect(!Self.keys(of: object).contains { $0.lowercased().contains("allerg") })
    }

    @Test func theAllergyCheckWouldCatchOne() {
        struct Leaky { let note: String; let allergies: [Allergen] }
        #expect(Self.holdsAllergies(Mirror(reflecting: Leaky(note: "", allergies: []))))
    }

    private static func holdsAllergies(_ mirror: Mirror) -> Bool {
        mirror.children.contains { child in
            child.label?.lowercased().contains("allerg") == true
                || child.value is Allergen || child.value is [Allergen] || child.value is MemberAllergies
                || holdsAllergies(Mirror(reflecting: child.value))
        }
    }

    private static func keys(of object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys + dictionary.values.flatMap(keys(of:))
        }
        return (object as? [Any])?.flatMap(keys(of:)) ?? []
    }
}

struct ClaimCall: Equatable {
    let kinds: [AIJobKind]
    let job: UUID?
}

/// The queue's rules, in memory: a claim takes the oldest open job once; only a claimed job finishes.
actor FakeAIQueue {
    private(set) var jobs: [AIJob] = []
    private(set) var claims: [ClaimCall] = []
    private(set) var finishes: [UUID] = []
    private let offline: Bool
    private let refuseFinishing: Bool

    private struct Offline: Error {}
    private struct Refused: Error {}

    init(offline: Bool = false, refuseFinishing: Bool = false) {
        self.offline = offline
        self.refuseFinishing = refuseFinishing
    }

    nonisolated var client: AIJobClient {
        AIJobClient(
            submit: { household, request in try await self.submit(household, request) },
            claim: { kinds, job in try await self.claim(kinds, job) },
            complete: { id, result in try await self.finish(id, status: .done, result: result, error: nil) },
            fail: { id, reason in try await self.finish(id, status: .failed, result: nil, error: reason) },
            recent: { household in try await self.recent(household) }
        )
    }

    private func submit(_ household: UUID, _ request: AIJobRequest) throws -> AIJob {
        guard !offline else { throw Offline() }
        let job = AIJob(id: UUID(), householdID: household, kind: request.kind, payload: try request.payload(),
                        status: .queued, result: nil, error: nil, updatedAt: .now)
        jobs.append(job)
        return job
    }

    private func claim(_ kinds: [AIJobKind], _ only: UUID?) throws -> AIJob? {
        guard !offline else { throw Offline() }
        claims.append(ClaimCall(kinds: kinds, job: only))
        guard let index = jobs.firstIndex(where: { job in
            job.status == .queued && job.kind.map(kinds.contains) == true && (only == nil || job.id == only)
        }) else { return nil }
        jobs[index] = jobs[index].with(status: .claimed)
        return jobs[index]
    }

    private func finish(_ id: UUID, status: AIJobStatus, result: Data?, error: String?) throws -> AIJob {
        guard !refuseFinishing, let index = jobs.firstIndex(where: { $0.id == id && $0.status == .claimed })
        else { throw Refused() }
        finishes.append(id)
        jobs[index] = jobs[index].with(status: status, result: result, error: error)
        return jobs[index]
    }

    private func recent(_ household: UUID) throws -> [AIJob] {
        guard !offline else { throw Offline() }
        return jobs.filter { $0.householdID == household }
    }
}

/// What the screens see (#58): a refresh runs what's waiting here, then shows every device's results.
@MainActor
struct AIQueueStoreTests {
    private let household = UUID()

    @Test func aRefreshRunsWhatsWaitingThenLoadsTheResults() async {
        let queue = FakeAIQueue()
        _ = await AIJobRunner(client: queue.client, ai: .stub(canRun: false))
            .submit(.echo(EchoPayload(text: "chili")), householdID: household)
        let store = AIQueueStore(householdID: household, runner: AIJobRunner(client: queue.client, ai: .stub(canRun: true)))

        await store.refresh()

        #expect(store.jobs.map(\.status) == [.done])
    }

    @Test func aDeviceThatCantRunTheModelStillSeesOthersResults() async throws {
        let queue = FakeAIQueue()
        _ = await AIJobRunner(client: queue.client, ai: .stub(canRun: true))
            .submit(.echo(EchoPayload(text: "chili")), householdID: household)
        let store = AIQueueStore(householdID: household, runner: AIJobRunner(client: queue.client, ai: .stub(canRun: false)))

        await store.refresh()

        #expect(store.jobs.first?.status == .done)
        #expect(try store.jobs.first?.decodedResult(EchoPayload.self) == EchoPayload(text: "chili"))
    }

    @Test func offlineKeepsWhatWasLoaded() async {
        let store = AIQueueStore(householdID: household,
                                 runner: AIJobRunner(client: FakeAIQueue(offline: true).client, ai: .stub(canRun: true)))

        await store.refresh()
        #expect(await store.submit(.echo(EchoPayload(text: "x"))) == nil)

        #expect(store.jobs.isEmpty)
    }
}

/// A model call's outcome as a job's (#58): only an answer is a result, and only a model that went away leaves the claim.
struct AIOutcomeJobTests {
    private let encode: (String) throws -> Data = { Data($0.utf8) }

    @Test func anAnswerIsTheResult() {
        #expect(AIOutcome.done("{}").jobOutcome(encode) == .done(Data("{}".utf8)))
    }

    @Test func noAnswerEndsTheJob() {
        #expect(AIOutcome<String>.timedOut.jobOutcome(encode) == .failed("timed out"))
        #expect(AIOutcome<String>.failed.jobOutcome(encode) == .failed("model failed"))
    }

    @Test func aModelThatWentAwayLeavesTheClaim() {
        #expect(AIOutcome<String>.unavailable.jobOutcome(encode) == .unavailable)
    }
}

extension AIService {
    /// The model's never asked: these tests are about the queue.
    static func stub(canRun: Bool) -> AIService {
        AIService(availability: { canRun ? .available : .unavailable(.deviceNotEligible) },
                  respond: { _, _, _ in throw CancellationError() })
    }
}
