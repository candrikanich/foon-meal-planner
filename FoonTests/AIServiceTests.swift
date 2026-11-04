import Foundation
import FoundationModels
import Testing
@testable import Foon

/// The on-device model as a helper (#58): unavailable, too slow or failing all mean the non-AI path, and none of them blocks.
struct AIServiceTests {
    @Generable
    struct Dish: Equatable {
        var name: String
        var minutes: Int
    }

    private struct ModelBroke: Error {}

    private func service(available: Bool = true, timeout: Duration = .seconds(5),
                         respond: @escaping @Sendable (String, String, GenerationSchema) async throws -> GeneratedContent)
        -> AIService {
        AIService(availability: { available ? .available : .unavailable(.deviceNotEligible) }, respond: respond,
                  timeout: timeout)
    }

    @Test func aCapableDeviceGetsTheModelsStructuredAnswer() async {
        let ai = service { _, _, _ in Dish(name: "Tacos", minutes: 20).generatedContent }

        let outcome = await ai.generate(Dish.self, instructions: "Name a dinner.", prompt: "Something quick")

        #expect(ai.canRun)
        #expect(outcome == .done(Dish(name: "Tacos", minutes: 20)))
    }

    @Test func theInstructionsPromptAndSchemaReachTheModel() async {
        let seen = Seen()
        let ai = service { instructions, prompt, schema in
            await seen.record(instructions, prompt, schema.debugDescription)
            return Dish(name: "Soup", minutes: 30).generatedContent
        }

        _ = await ai.generate(Dish.self, instructions: "Name a dinner.", prompt: "Something warm")

        #expect(await seen.instructions == "Name a dinner.")
        #expect(await seen.prompt == "Something warm")
        #expect(await seen.schema.contains("minutes"))
    }

    @Test func aDeviceWithoutTheModelNeverCallsIt() async {
        let ai = service(available: false) { _, _, _ in
            Issue.record("the model was called on a device that can't run it")
            return Dish(name: "", minutes: 0).generatedContent
        }

        #expect(!ai.canRun)
        #expect(await ai.generate(Dish.self, instructions: "", prompt: "") == .unavailable)
    }

    @Test func aModelThatNeverAnswersTimesOutWithoutBlocking() async {
        // Ignores cancellation on purpose: the call must come back on time anyway.
        let ai = service(timeout: .milliseconds(50)) { _, _, _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return Dish(name: "Never", minutes: 0).generatedContent
        }
        let started = ContinuousClock.now

        let outcome = await ai.generate(Dish.self, instructions: "", prompt: "")

        #expect(outcome == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aModelErrorIsTheNonAIPath() async {
        let ai = service { _, _, _ in throw ModelBroke() }

        #expect(await ai.generate(Dish.self, instructions: "", prompt: "") == .failed)
    }

    @Test func anAnswerThatDoesntFitTheShapeIsAFailure() async throws {
        let wrongShape = try GeneratedContent(json: #"{"title": "Tacos"}"#)
        let ai = service { _, _, _ in wrongShape }

        #expect(await ai.generate(Dish.self, instructions: "", prompt: "") == .failed)
    }

    @Test func cancellingTheCallerEndsTheWaitToo() async {
        let ai = service(timeout: .seconds(60)) { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return Dish(name: "Late", minutes: 0).generatedContent
        }
        let started = ContinuousClock.now
        let call = Task { await ai.generate(Dish.self, instructions: "", prompt: "") }

        try? await Task.sleep(for: .milliseconds(20))
        call.cancel()

        #expect(await call.value == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(arguments: [
        (SystemLanguageModel.Availability.available, AIAvailability.available),
        (.unavailable(.deviceNotEligible), .unavailable(.deviceNotEligible)),
        (.unavailable(.appleIntelligenceNotEnabled), .unavailable(.appleIntelligenceNotEnabled)),
        (.unavailable(.modelNotReady), .unavailable(.modelNotReady))
    ])
    func theSystemsAnswerMapsToOurs(system: SystemLanguageModel.Availability, expected: AIAvailability) {
        #expect(AIAvailability(system) == expected)
    }
}

private actor Seen {
    var instructions = ""
    var prompt = ""
    var schema = ""

    func record(_ instructions: String, _ prompt: String, _ schema: String) {
        self.instructions = instructions
        self.prompt = prompt
        self.schema = schema
    }
}
