import Foundation
import Supabase

/// The household's AI queue in Supabase (`ai_jobs`), as closures so tests run the queue in memory.
struct AIJobClient: Sendable {
    var submit: @Sendable (_ householdID: UUID, _ request: AIJobRequest) async throws -> AIJob
    /// The oldest claimable job of these kinds in the caller's household, or this one. Nil when there's none.
    var claim: @Sendable (_ kinds: [AIJobKind], _ job: UUID?) async throws -> AIJob?
    var complete: @Sendable (_ job: UUID, _ result: Data) async throws -> AIJob
    var fail: @Sendable (_ job: UUID, _ reason: String) async throws -> AIJob
    /// The household's jobs, newest first: how other devices see results.
    var recent: @Sendable (_ householdID: UUID) async throws -> [AIJob]
}

extension AIJobClient {
    static func live(_ client: SupabaseClient) -> AIJobClient {
        AIJobClient(
            submit: { householdID, request in
                let payload = try JSONDecoder().decode(AnyJSON.self, from: request.payload())
                let row: AIJobRow = try await client.rpc("submit_ai_job", params: SubmitParams(
                    targetHousehold: householdID, jobKind: request.kind.rawValue, jobPayload: payload
                )).execute().value
                return try row.job()
            },
            claim: { kinds, job in
                let rows: [AIJobRow] = try await client.rpc("claim_ai_job", params: ClaimParams(
                    jobKinds: kinds.map(\.rawValue), onlyJob: job
                )).execute().value
                return try rows.first?.job()
            },
            complete: { job, result in
                let row: AIJobRow = try await client.rpc("complete_ai_job", params: CompleteParams(
                    job: job, jobResult: try JSONDecoder().decode(AnyJSON.self, from: result)
                )).execute().value
                return try row.job()
            },
            fail: { job, reason in
                let row: AIJobRow = try await client.rpc("fail_ai_job", params: FailParams(job: job, reason: reason))
                    .execute().value
                return try row.job()
            },
            recent: { householdID in
                let rows: [AIJobRow] = try await client.from("ai_jobs")
                    .select("id, household_id, kind, payload, status, result, error, updated_at")
                    .eq("household_id", value: householdID)
                    .order("created_at", ascending: false)
                    .limit(50)
                    .execute()
                    .value
                return try rows.map { try $0.job() }
            }
        )
    }

    /// Previews: nothing's queued and nothing's sent.
    static let preview = AIJobClient(
        submit: { _, _ in throw CancellationError() }, claim: { _, _ in nil },
        complete: { _, _ in throw CancellationError() }, fail: { _, _ in throw CancellationError() },
        recent: { _ in [] }
    )
}

private struct SubmitParams: Encodable {
    let targetHousehold: UUID
    let jobKind: String
    let jobPayload: AnyJSON

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household", jobKind = "job_kind", jobPayload = "job_payload"
    }
}

private struct ClaimParams: Encodable {
    let jobKinds: [String]
    let onlyJob: UUID?

    enum CodingKeys: String, CodingKey { case jobKinds = "job_kinds", onlyJob = "only_job" }
}

private struct CompleteParams: Encodable {
    let job: UUID
    let jobResult: AnyJSON

    enum CodingKeys: String, CodingKey { case job, jobResult = "job_result" }
}

private struct FailParams: Encodable {
    let job: UUID
    let reason: String
}

private struct AIJobRow: Decodable {
    let id: UUID
    let householdID: UUID
    let kind: String
    let payload: AnyJSON
    let status: AIJobStatus
    let result: AnyJSON?
    let error: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, householdID = "household_id", kind, payload, status, result, error, updatedAt = "updated_at"
    }

    func job() throws -> AIJob {
        let encoder = JSONEncoder()
        return AIJob(id: id, householdID: householdID, kind: AIJobKind(rawValue: kind), payload: try encoder.encode(payload),
                     status: status, result: try result.map { try encoder.encode($0) }, error: error, updatedAt: updatedAt)
    }
}
