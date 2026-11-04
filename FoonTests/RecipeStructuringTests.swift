import Foundation
import FoundationModels
import Testing
@testable import Foon

/// Recipe structuring (#59): captured text in, a tidy recipe out, through the household queue. The model is stubbed: CI and
/// the simulator usually lack Apple Intelligence.
struct RecipeStructuringTests {
    private static let answer = GeneratedRecipe(
        name: "  Grandma's Chili ", servings: 6,
        ingredients: ["2 lb ground beef", " ", "1 can kidney beans", "1 onion"],
        steps: ["Brown the beef.", "", "Simmer for an hour."],
        prepSteps: [GeneratedPrepStep(step: "Soak the beans overnight", hoursAhead: 24)]
    )

    private func ai(timeout: Duration = .seconds(5),
                    respond: @escaping @Sendable (String, String, GenerationSchema) async throws -> GeneratedContent)
        -> AIService {
        AIService(availability: { .available }, respond: respond, timeout: timeout)
    }

    // MARK: Payload

    @Test func thePayloadIsTheTextAndTheLinkOnly() throws {
        let payload = RecipeJobPayload(text: "Chili\n2 lb beef", sourceURL: URL(string: "https://www.instagram.com/p/abc"))
        let object = try #require(JSONSerialization.jsonObject(with: AIJobRequest.recipe(payload).payload()) as? [String: Any])

        #expect(Set(object.keys) == ["text", "source_url"])
        #expect(object["text"] as? String == "Chili\n2 lb beef")
        #expect(AIJobRequest.recipe(payload).kind == .recipe)
    }

    @Test func longTextIsCutToFitTheModelAndTheQueue() throws {
        let payload = RecipeJobPayload(text: String(repeating: "beans ", count: 5_000))
        #expect(payload.text.unicodeScalars.count <= RecipeJobPayload.textLimit)

        let wide = RecipeJobPayload(text: String(repeating: "🌶", count: 8_000))
        #expect(wide.text.utf8.count <= RecipeJobPayload.byteLimit)
        #expect(try AIJobRequest.recipe(wide).payload().count < 32_768)
    }

    @Test func onlyAWebLinkIsSent() {
        #expect(RecipeJobPayload(text: "x", sourceURL: URL(string: "file:///private/recipe.pdf")).sourceURL == nil)
        #expect(RecipeJobPayload(text: "x", sourceURL: nil).sourceURL == nil)
    }

    // MARK: Output

    @Test func theModelsAnswerIsTrimmedToWhatAMealHolds() {
        let recipe = StructuredRecipe(Self.answer)

        #expect(recipe.name == "Grandma's Chili")
        #expect(recipe.servings == 6)
        #expect(recipe.ingredients == ["2 lb ground beef", "1 can kidney beans", "1 onion"])
        #expect(recipe.steps == ["Brown the beef.", "Simmer for an hour."])
        #expect(recipe.prepSteps == [PrepStep(step: "Soak the beans overnight", leadHours: 24)])
    }

    @Test func noServingsAndOddLeadsAreKeptSensible() {
        let odd = GeneratedRecipe(name: "Soup", servings: 0, ingredients: [], steps: [],
                                  prepSteps: [GeneratedPrepStep(step: "Thaw", hoursAhead: 500),
                                              GeneratedPrepStep(step: " ", hoursAhead: 4)])
        let recipe = StructuredRecipe(odd)

        #expect(recipe.servings == nil)
        #expect(recipe.prepSteps == [PrepStep(step: "Thaw", leadHours: 48)])
    }

    @Test func tooMuchIsCutAtTheMealsLimits() {
        let long = GeneratedRecipe(name: String(repeating: "a", count: 200), servings: 4,
                                   ingredients: (1...90).map { "item \($0)" }, steps: (1...70).map { "step \($0)" },
                                   prepSteps: (1...15).map { GeneratedPrepStep(step: "prep \($0)", hoursAhead: 2) })
        let recipe = StructuredRecipe(long)

        #expect(recipe.name.count == 80)
        #expect(recipe.ingredients.count == 60)
        #expect(recipe.steps.count == 50)
        #expect(recipe.prepSteps.count == 10)
    }

    @Test func theResultRoundTripsAndFitsTheQueue() throws {
        let huge = StructuredRecipe(name: "Stew", servings: 4, ingredients: [],
                                    steps: (1...50).map { _ in String(repeating: "stir ", count: 200) }, prepSteps: [])
        let data = try huge.encoded()

        #expect(data.count <= StructuredRecipe.byteLimit)
        let back = try JSONDecoder().decode(StructuredRecipe.self, from: data)
        #expect(back.steps.count < 50)
        #expect(back.name == "Stew")
    }

    @Test func aDraftIsScaledToTheFamilyLikeAPlainRead() {
        let recipe = StructuredRecipe(name: "Chili", servings: 8, ingredients: ["2 lb ground beef", "salt"],
                                      steps: ["Brown it"], prepSteps: [PrepStep(step: "Thaw the beef", leadHours: 24)])
        let draft = recipe.draft(householdSize: 4)

        #expect(draft.name == "Chili")
        #expect(draft.servings == 4)
        #expect(draft.lines.map(\.quantity) == ["1 lb", ""])
        #expect(draft.lines.map(\.name) == ["ground beef", "salt"])
        #expect(draft.stepsText == "Brown it")
        #expect(draft.prepLines.map(\.step) == ["Thaw the beef"])
    }

    // MARK: The handler

    @Test func theHandlerAsksTheModelWithTheTextAndReturnsTheRecipe() async throws {
        let seen = Prompted()
        let model = ai { instructions, prompt, _ in
            await seen.record(instructions, prompt)
            return Self.answer.generatedContent
        }
        let payload = try AIJobRequest.recipe(RecipeJobPayload(text: "chili text")).payload()
        let handler = try #require(AIJobKind.handlers[.recipe])

        let outcome = await handler(payload, model)

        guard case .done(let data) = outcome else { Issue.record("expected a result, got \(outcome)"); return }
        #expect(try JSONDecoder().decode(StructuredRecipe.self, from: data).name == "Grandma's Chili")
        #expect(await seen.prompt.contains("chili text"))
        #expect(await seen.instructions == RecipeStructuring.instructions)
        #expect(!RecipeStructuring.instructions.lowercased().contains("allerg"))
    }

    @Test func aModelThatTimesOutFailsTheJob() async throws {
        let slow = ai(timeout: .milliseconds(50)) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.answer.generatedContent
        }
        let payload = try AIJobRequest.recipe(RecipeJobPayload(text: "x")).payload()

        #expect(await RecipeStructuring.handle(payload, slow) == .failed("timed out"))
    }

    @Test func anAnswerWithNothingInItIsAFailure() async throws {
        let empty = ai { _, _, _ in
            GeneratedRecipe(name: " ", servings: 0, ingredients: [], steps: [], prepSteps: []).generatedContent
        }
        let payload = try AIJobRequest.recipe(RecipeJobPayload(text: "x")).payload()

        #expect(await RecipeStructuring.handle(payload, empty) == .failed("empty recipe"))
    }

    @Test func anUnreadablePayloadOrAModelThatWentAwayIsHandled() async throws {
        let model = ai { _, _, _ in Self.answer.generatedContent }
        #expect(await RecipeStructuring.handle(Data("{}".utf8), model) == .failed("unreadable payload"))

        let gone = AIService(availability: { .unavailable(.modelNotReady) }, respond: { _, _, _ in throw CancellationError() })
        let payload = try AIJobRequest.recipe(RecipeJobPayload(text: "x")).payload()
        #expect(await RecipeStructuring.handle(payload, gone) == .unavailable)
    }
}

private actor Prompted {
    var instructions = ""
    var prompt = ""

    func record(_ instructions: String, _ prompt: String) {
        self.instructions = instructions
        self.prompt = prompt
    }
}

/// Applying a result (#59): a field changes only if nobody's touched it since the plain read.
struct RecipeMergeTests {
    private func plainRead() -> MealDraft {
        var draft = MealDraft(newNamed: "CHILI!!")
        draft.servings = 4
        draft.lines = [MealDraft.Line(quantity: "2 lb", name: "ground beef"), MealDraft.Line(quantity: "", name: "Rating 4.8")]
        draft.stepsText = "1. Brown the beef\nPrep 10 min"
        return draft
    }

    private let recipe = StructuredRecipe(name: "Chili", servings: 4, ingredients: ["2 lb ground beef", "1 onion"],
                                          steps: ["Brown the beef", "Simmer"],
                                          prepSteps: [PrepStep(step: "Thaw the beef", leadHours: 24)])

    @Test func anUntouchedReadTakesTheWholeResult() throws {
        let read = plainRead()
        let merged = try #require(RecipeMerge.merged(read, baseline: RecipeBaseline(read), recipe: recipe))

        #expect(merged.name == "Chili")
        #expect(merged.lines.map(\.name) == ["ground beef", "onion"])
        #expect(merged.stepsText == "Brown the beef\nSimmer")
        #expect(merged.prepLines.map(\.step) == ["Thaw the beef"])
        #expect(merged.servings == 4)
    }

    @Test func aFieldSomeoneEditedIsLeftAlone() throws {
        let read = plainRead()
        var edited = read
        edited.name = "Dad's chili"
        edited.lines[1].name = "cumin"

        let merged = try #require(RecipeMerge.merged(edited, baseline: RecipeBaseline(read), recipe: recipe))

        #expect(merged.name == "Dad's chili")
        #expect(merged.lines.map(\.name) == ["ground beef", "cumin"])
        #expect(merged.stepsText == "Brown the beef\nSimmer")
    }

    @Test func aNameThePersonGaveIsNeverReplaced() throws {
        let read = plainRead()
        let merged = try #require(RecipeMerge.merged(read, baseline: RecipeBaseline(read, nameIsTheirs: true), recipe: recipe))

        #expect(merged.name == "CHILI!!")
    }

    @Test func aSavedMealReadsTheSameAsTheDraftItCameFrom() throws {
        let read = plainRead()
        // Saved: numbering dropped, blank amounts as nil, and the item name as the server spells it.
        let meal = LibraryMeal(
            id: UUID(), householdID: UUID(), name: "CHILI!!", servings: 4, tags: [], status: .active, createdAt: .now,
            ingredients: [MealIngredient(itemID: UUID(), name: "Ground beef", quantityText: "2 lb", position: 0),
                          MealIngredient(itemID: UUID(), name: "Rating 4.8", quantityText: nil, position: 1)],
            steps: ["Brown the beef", "Prep 10 min"], prepSteps: []
        )

        #expect(RecipeBaseline(MealDraft(meal)) == RecipeBaseline(read))
        let merged = try #require(RecipeMerge.merged(MealDraft(meal), baseline: RecipeBaseline(read), recipe: recipe))
        #expect(merged.name == "Chili")
    }

    @Test func everythingEditedMeansNothingToSave() {
        let read = plainRead()
        var edited = read
        edited.name = "Mine"
        edited.lines = []
        edited.stepsText = "My way"
        edited.prepLines = [MealDraft.PrepLine(step: "Chop ahead", leadHours: 2)]

        #expect(RecipeMerge.merged(edited, baseline: RecipeBaseline(read), recipe: recipe) == nil)
    }

    @Test func anEmptyPartOfTheResultKeepsThePlainRead() throws {
        let read = plainRead()
        let sparse = StructuredRecipe(name: "Chili", servings: nil, ingredients: [], steps: [], prepSteps: [])

        let merged = try #require(RecipeMerge.merged(read, baseline: RecipeBaseline(read), recipe: sparse))

        #expect(merged.lines == read.lines)
        #expect(merged.stepsText == read.stepsText)
    }

    @Test func anAllergenTheModelDroppedStaysOnTheDish() throws {
        var read = plainRead()
        read.lines.append(MealDraft.Line(quantity: "1/4 cup", name: "peanuts"))

        let merged = try #require(RecipeMerge.merged(read, baseline: RecipeBaseline(read), recipe: recipe))

        #expect(merged.lines.map(\.name) == ["ground beef", "onion", "peanuts"])
        #expect(!merged.lines.map(\.name).contains("Rating 4.8"))
    }

    @Test func theFallbackIsThePlainReadWithKeywordPrepSuggestions() {
        // No result (failed, timed out, expired): nothing merges, and the editor still offers prep by keyword.
        var read = plainRead()
        read.stepsText = "Marinate the beef overnight"

        let offered = PrepSuggestions.suggestions(name: read.name, ingredients: read.lines.map(\.name),
                                                  steps: read.stepsText, tags: [], existing: [], keepsMeatFrozen: false)

        #expect(offered == [PrepStep(step: String(localized: "Marinate", comment: "Suggested prep step"), leadHours: 12)])
    }
}
