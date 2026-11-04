import Foundation
import FoundationModels
import Testing
@testable import Foon

/// What the screens see (#58, #59): a capable device runs its own job without holding the screen, results reach the device
/// waiting on them, and a refresh loads only the jobs this device is waiting on, never their payloads.
@MainActor
struct AIQueueStoreTests {
    private let household = UUID()
    private let recipe = StructuredRecipe(name: "Chili", servings: 4, ingredients: ["2 lb ground beef", "1 onion"],
                                          steps: ["Brown the beef"], prepSteps: [])
    private let request = AIJobRequest.recipe(RecipeJobPayload(text: "chili\n2 lb beef"))
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

    private func store(_ queue: FakeAIQueue, ai: AIService, shelf: AIWatchShelf = .memory()) -> AIQueueStore {
        AIQueueStore(householdID: household, runner: AIJobRunner(client: queue.client, ai: ai), shelf: shelf)
    }

    @Test func aCapableDeviceRunsItsOwnRecipeAndTheResultIsThere() async throws {
        let queue = FakeAIQueue()
        let store = store(queue, ai: model(recipe))

        let job = try #require(await store.submit(request))
        await store.ownRunsFinished()

        #expect(!store.isProcessing(job))
        #expect(store.recipe(for: job) == recipe)
        #expect(await queue.jobs.first?.status == .done)
    }

    @Test func aTimedOutOrFailedRunClearsTheMarkAndLeavesNoResult() async throws {
        let queue = FakeAIQueue()
        let store = store(queue, ai: model(nil))

        let job = try #require(await store.submit(request))
        await store.ownRunsFinished()

        #expect(!store.isProcessing(job))
        #expect(store.recipe(for: job) == nil)
        #expect(await queue.jobs.first?.status == .failed)
    }

    @Test func aDeviceThatCantRunTheModelWaitsForAFamilyDevice() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let job = try #require(await phone.submit(request))
        await phone.ownRunsFinished()
        #expect(phone.isProcessing(job))

        await store(queue, ai: model(recipe)).refresh()
        await phone.refresh()

        #expect(phone.recipe(for: job) == recipe)
        #expect(!phone.isProcessing(job))
    }

    @Test func aMealSavedBeforeTheResultGetsItWhenItArrives() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = Applied()
        phone.applyRecipe = { watch, recipe in
            applied.calls.append(Applied.Call(meal: watch.mealID, recipe: recipe))
            return .finished
        }
        let meal = UUID()
        let job = try #require(await phone.submit(request))
        phone.watch(job, meal: meal, baseline: baseline)
        #expect(phone.isProcessing(meal: meal))

        await store(queue, ai: model(recipe)).refresh()
        await phone.refresh()

        #expect(applied.calls == [Applied.Call(meal: meal, recipe: recipe)])
        #expect(!phone.isProcessing(meal: meal))
        #expect(phone.watches.isEmpty)
    }

    @Test func aSaveBeforeThisDevicesOwnRunFinishesIsAppliedToo() async throws {
        let queue = FakeAIQueue()
        let gate = AsyncStream<Void>.makeStream()
        let answer = GeneratedRecipe(name: recipe.name, servings: 4, ingredients: recipe.ingredients, steps: recipe.steps,
                                     prepSteps: [])
        let slow = AIService(availability: { .available }, respond: { _, _, _ in
            for await _ in gate.stream { break }
            return answer.generatedContent
        })
        let store = store(queue, ai: slow)
        let applied = Applied()
        store.applyRecipe = { watch, recipe in
            applied.calls.append(Applied.Call(meal: watch.mealID, recipe: recipe))
            return .finished
        }
        let meal = UUID()

        let job = try #require(await store.submit(request))
        store.watch(job, meal: meal, baseline: baseline)
        gate.continuation.yield()
        gate.continuation.finish()
        await store.ownRunsFinished()

        #expect(applied.calls.map(\.meal) == [meal])
        #expect(store.watches.isEmpty)
    }

    @Test func aResultAlreadyMergedInTheSheetIsntWatched() async throws {
        let queue = FakeAIQueue()
        let store = store(queue, ai: model(recipe))
        let job = try #require(await store.submit(request))
        await store.ownRunsFinished()

        store.watch(job, meal: UUID(), baseline: baseline)

        #expect(store.watches.isEmpty)
    }

    @Test func aJobThatExpiresDropsTheWatchAndTheNonAIResultStays() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = Applied()
        phone.applyRecipe = { watch, recipe in
            applied.calls.append(Applied.Call(meal: watch.mealID, recipe: recipe))
            return .finished
        }
        let meal = UUID()
        let job = try #require(await phone.submit(request))
        phone.watch(job, meal: meal, baseline: baseline)

        await queue.expire(job)
        await phone.refresh()

        #expect(applied.calls.isEmpty)
        #expect(!phone.isProcessing(meal: meal))
        #expect(phone.watches.isEmpty)
    }

    @Test func aMealNotLoadedYetIsTriedAgainNextTime() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))
        let applied = Applied()
        phone.applyRecipe = { _, _ in applied.ready ? .finished : .retry }
        let job = try #require(await phone.submit(request))
        phone.watch(job, meal: UUID(), baseline: baseline)
        await store(queue, ai: model(recipe)).refresh()

        await phone.refresh()
        #expect(phone.watches.count == 1)

        applied.ready = true
        await phone.refresh()
        #expect(phone.watches.isEmpty)
    }

    @Test func watchesOutliveTheAppAndGoOnceTheJobCantStillBeWaiting() async throws {
        let shelf = AIWatchShelf.memory()
        let old = RecipeWatch(jobID: UUID(), mealID: UUID(), baseline: baseline,
                              submittedAt: .now.addingTimeInterval(-4 * 86_400))
        let fresh = RecipeWatch(jobID: UUID(), mealID: UUID(), baseline: baseline, submittedAt: .now)
        shelf.save([old, fresh])

        let phone = store(FakeAIQueue(), ai: .stub(canRun: false), shelf: shelf)
        #expect(phone.isProcessing(meal: fresh.mealID))
        await phone.refresh()

        // Neither is in the queue: the old one's past any expiry and was pruned; the fresh one may just be on its way.
        #expect(phone.watches == [fresh])
        #expect(shelf.load() == [fresh])
    }

    @Test func nothingIsLoadedWhenNothingsWaiting() async throws {
        let queue = FakeAIQueue()
        let phone = store(queue, ai: .stub(canRun: false))

        await phone.refresh()
        #expect(await queue.statusLoads.isEmpty)

        let job = try #require(await phone.submit(request))
        await phone.refresh()
        #expect(await queue.statusLoads == [[job]])
    }

    @Test func offlineQueuesNothingAndNeverThrows() async {
        let phone = store(FakeAIQueue(offline: true), ai: model(recipe))

        await phone.refresh()
        #expect(await phone.submit(request) == nil)

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
    var ready = false
}
