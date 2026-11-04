import Foundation
import FoundationModels
import Testing
@testable import Foon

/// The household's AI on a device (#58, #59): a device that can run the model tidies a recipe itself and sends nothing; one
/// that can't queues it only when the dish is saved; each saved dish is followed until its result lands or ends.
@MainActor
struct AIQueueStoreTests {
    private let household = UUID()
    private let recipe = StructuredRecipe(name: "Chili", servings: 4, ingredients: ["2 lb ground beef", "1 onion"],
                                          steps: ["Brown the beef"], prepSteps: [])
    private let payload = RecipeJobPayload(text: "Chili\nIngredients:\n2 lb beef")
    private let baseline = RecipeBaseline(MealDraft(newNamed: ""))

    private func model(_ recipe: StructuredRecipe?) -> AIService {
        let answer = recipe.map {
            GeneratedRecipe(name: $0.name, servings: $0.servings ?? 0, ingredients: $0.ingredients, steps: $0.steps,
                            prepSteps: [])
        }
        return AIService(availability: { .available }, respond: { _, _, _ in
            guard let answer else { throw CancellationError() }
            return answer.generatedContent
        })
    }

    private func store(_ queue: FakeAIQueue, ai: AIService, shelf: AIWatchShelf = .memory(),
                       tidyLimit: Duration = RecipeStructuring.timeLimit,
                       now: @escaping @Sendable () -> Date = { .now }) -> AIQueueStore {
        let store = AIQueueStore(householdID: household, runner: AIJobRunner(client: queue.client, ai: ai), shelf: shelf,
                                 tidyLimit: tidyLimit, now: now)
        store.isPlanner = true
        return store
    }

    private func recording(_ store: AIQueueStore, outcome: AIQueueStore.ApplyOutcome = .applied) -> Applied {
        let applied = Applied()
        store.applyRecipe = { watch, recipe in
            applied.calls.append(Applied.Call(meal: watch.mealID, recipe: recipe))
            return applied.next ?? outcome
        }
        return applied
    }

    // MARK: A device that can run the model

    @Test func aCapableDeviceTidiesHereAndSendsNothing() async throws {
        let queue = FakeAIQueue()
        let store = store(queue, ai: model(recipe))

        let token = try #require(store.tidyHere(payload))
        await store.tidyingFinished()

        #expect(store.tidied[token] == recipe)
        #expect(await queue.jobs.isEmpty)
    }

    @Test func aDishSavedBeforeTheRunFinishesGetsItsResult() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let answer = GeneratedRecipe(name: "Chili", servings: 4, ingredients: recipe.ingredients, steps: recipe.steps,
                                     prepSteps: [])
        let slow = AIService(availability: { .available }, respond: { _, _, _ in
            for await _ in gate.stream { break }
            return answer.generatedContent
        })
        let queue = FakeAIQueue()
        let store = store(queue, ai: slow)
        let applied = recording(store)
        let meal = UUID()

        let token = try #require(store.tidyHere(payload))
        await store.saved(meal: meal, baseline: baseline, token: token, alreadyTaken: false, payload: payload)
        #expect(store.isProcessing(meal: meal))
        gate.continuation.yield()
        gate.continuation.finish()
        await store.tidyingFinished()

        #expect(applied.calls == [Applied.Call(meal: meal, recipe: recipe)])
        #expect(store.watches.isEmpty)
        #expect(await queue.jobs.isEmpty)
    }

    @Test func aResultThatCameDuringTheSaveButWasntMergedIsStillApplied() async throws {
        let store = store(FakeAIQueue(), ai: model(recipe))
        let applied = recording(store)
        let token = try #require(store.tidyHere(payload))
        await store.tidyingFinished()

        await store.saved(meal: UUID(), baseline: baseline, token: token, alreadyTaken: false, payload: payload)

        #expect(applied.calls.count == 1)
        #expect(store.watches.isEmpty)
    }

    @Test func aResultTheReviewScreenAlreadyTookIsntAppliedAgain() async throws {
        let store = store(FakeAIQueue(), ai: model(recipe))
        let applied = recording(store)
        let token = try #require(store.tidyHere(payload))
        await store.tidyingFinished()

        await store.saved(meal: UUID(), baseline: baseline, token: token, alreadyTaken: true, payload: payload)

        #expect(applied.calls.isEmpty)
        #expect(store.watches.isEmpty)
    }

    @Test func aTimedOutOrFailedRunHereLeavesThePlainRead() async throws {
        let store = store(FakeAIQueue(), ai: model(nil))
        let applied = recording(store)
        let meal = UUID()
        let token = try #require(store.tidyHere(payload))
        await store.tidyingFinished()

        await store.saved(meal: meal, baseline: baseline, token: token, alreadyTaken: false, payload: payload)

        #expect(store.tidied[token] == nil)
        #expect(applied.calls.isEmpty)
        #expect(!store.isProcessing(meal: meal))
    }

    @Test func aRunThatEndsEmptyHandedSaysSoSoTheSheetCanBeHonest() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let stuck = AIService(availability: { .available }, respond: { _, _, _ in
            for await _ in gate.stream { break }
            throw CancellationError()
        })
        let failing = store(FakeAIQueue(), ai: stuck)
        let token = try #require(failing.tidyHere(payload))
        #expect(!failing.gaveUp(token))
        gate.continuation.finish()
        await failing.tidyingFinished()
        #expect(failing.gaveUp(token))

        let working = store(FakeAIQueue(), ai: model(recipe))
        let tidied = try #require(working.tidyHere(payload))
        await working.tidyingFinished()
        #expect(!working.gaveUp(tidied))
    }

    @Test func aRecipeTidiedHereGetsTheLongerRecipeLimit() async throws {
        #expect(RecipeStructuring.timeLimit == .seconds(45))
        let answer = GeneratedRecipe(name: "Chili", servings: 4, ingredients: recipe.ingredients, steps: recipe.steps,
                                     prepSteps: [])
        let unhurried = AIService(availability: { .available }, respond: { _, _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return answer.generatedContent
        }, timeout: .milliseconds(50))

        let patient = store(FakeAIQueue(), ai: unhurried, tidyLimit: .seconds(5))
        let token = try #require(patient.tidyHere(payload))
        await patient.tidyingFinished()
        #expect(patient.tidied[token] == recipe)

        let hasty = store(FakeAIQueue(), ai: unhurried, tidyLimit: .milliseconds(50))
        let cut = try #require(hasty.tidyHere(payload))
        await hasty.tidyingFinished()
        #expect(hasty.gaveUp(cut))
    }

    @Test func closingWithoutADishForgetsTheRun() async throws {
        let store = store(FakeAIQueue(), ai: model(recipe))
        let token = try #require(store.tidyHere(payload))

        store.forget(token)
        await store.tidyingFinished()

        #expect(store.tidied[token] == nil)
        #expect(!store.isTidying(token))
    }

    // MARK: A device that can't

    @Test func aDeviceThatCantRunTheModelSendsNothingUntilTheDishIsSaved() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        #expect(phone.tidyHere(payload) == nil)
        #expect(await queue.jobs.isEmpty)

        let meal = UUID()
        await phone.saved(meal: meal, baseline: baseline, token: nil, alreadyTaken: false, payload: payload)

        #expect(await queue.jobs.map(\.kind) == [.recipe])
        #expect(phone.isProcessing(meal: meal))
    }

    @Test func aFamilyDevicesResultReachesTheSavedDish() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = recording(phone)
        let meal = UUID()
        await phone.saved(meal: meal, baseline: baseline, token: nil, alreadyTaken: false, payload: payload)

        await store(queue, ai: model(recipe)).refresh()
        await phone.refresh()

        #expect(applied.calls == [Applied.Call(meal: meal, recipe: recipe)])
        #expect(!phone.isProcessing(meal: meal))
    }

    @Test func aMembersDeviceDoesntClaimRecipeJobs() async throws {
        let queue = FakeAIQueue()
        await store(queue, ai: .stub(canRun: false))
            .saved(meal: UUID(), baseline: baseline, token: nil, alreadyTaken: false, payload: payload)
        let member = store(queue, ai: model(recipe))
        member.isPlanner = false

        await member.refresh()

        #expect(await queue.jobs.map(\.status) == [.queued])
        #expect(await queue.claims.allSatisfy { !$0.kinds.contains(.recipe) })
    }

    @Test func aJobThatExpiresEndsTheWatchAndThePlainReadStays() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = recording(phone)
        let meal = UUID()
        await phone.saved(meal: meal, baseline: baseline, token: nil, alreadyTaken: false, payload: payload)
        let job = try #require(await queue.jobs.first?.id)

        await queue.expire(job)
        await phone.refresh()

        #expect(applied.calls.isEmpty)
        #expect(!phone.isProcessing(meal: meal))
    }

    // MARK: Retrying

    @Test func onlyATransientFailureIsTriedAgain() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = recording(phone)
        applied.next = .retry
        await phone.saved(meal: UUID(), baseline: baseline, token: nil, alreadyTaken: false, payload: payload)
        await store(queue, ai: model(recipe)).refresh()

        await phone.refresh()
        #expect(phone.watches.count == 1)

        applied.next = .finished
        await phone.refresh()
        #expect(phone.watches.isEmpty)
        #expect(applied.calls.count == 2)
    }

    @Test func aDoneResultThatKeepsFailingStillEndsWhenItsTimeIsUp() async throws {
        let queue = FakeAIQueue()
        let clock = Clock()
        let phone = store(queue, ai: .stub(canRun: false), now: { clock.now })
        let applied = recording(phone, outcome: .retry)
        await phone.saved(meal: UUID(), baseline: baseline, token: nil, alreadyTaken: false, payload: payload)
        await store(queue, ai: model(recipe)).refresh()
        await phone.refresh()
        #expect(phone.watches.count == 1)

        clock.now = clock.now.addingTimeInterval(AIQueueStore.watchLimit + 1)
        await phone.refresh()

        #expect(phone.watches.isEmpty)
        #expect(applied.calls.count == 1)
    }

    @Test func watchesOutliveTheAppAndARunHereThatEndedWithItGoes() async throws {
        let shelf = AIWatchShelf.memory()
        let queued = RecipeWatch(source: .job(UUID()), mealID: UUID(), baseline: baseline, submittedAt: .now)
        let old = RecipeWatch(source: .job(UUID()), mealID: UUID(), baseline: baseline,
                              submittedAt: .now.addingTimeInterval(-4 * 86_400))
        let here = RecipeWatch(source: .here(UUID()), mealID: UUID(), baseline: baseline, submittedAt: .now)
        shelf.save([queued, old, here])

        let phone = store(FakeAIQueue(), ai: .stub(canRun: false), shelf: shelf)
        #expect(phone.isProcessing(meal: queued.mealID))
        await phone.refresh()

        #expect(phone.watches == [queued])
        #expect(shelf.load() == [queued])
    }

    @Test func nothingIsLoadedWhenNothingsWaiting() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))

        await phone.refresh()
        #expect(await queue.statusLoads.isEmpty)

        await phone.saved(meal: UUID(), baseline: baseline, token: nil, alreadyTaken: false, payload: payload)
        let job = try #require(await queue.jobs.first?.id)
        await phone.refresh()
        #expect(await queue.statusLoads.contains([job]))
    }

    @Test func offlineQueuesNothingAndNeverThrows() async {
        let phone = store(FakeAIQueue(offline: true), ai: .stub(canRun: false))
        let meal = UUID()

        await phone.refresh()
        await phone.saved(meal: meal, baseline: baseline, token: nil, alreadyTaken: false, payload: payload)

        #expect(!phone.isProcessing(meal: meal))
        #expect(phone.jobs.isEmpty)
    }
}

@MainActor
private final class Applied {
    struct Call: Equatable {
        let meal: UUID
        let recipe: StructuredRecipe
    }

    var calls: [Call] = []
    var next: AIQueueStore.ApplyOutcome?
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date.now

    var now: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
