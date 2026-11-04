import Foundation
import FoundationModels

/// What a `recipe` job sends to the household's queue: the captured text and where it came from, nothing else. No allergies,
/// no members, no household size (CLAUDE.md rule 4): scaling and allergy checks happen on the device that shows the result.
struct RecipeJobPayload: Codable, Equatable, Sendable {
    /// About 2,000 tokens of English, which leaves the on-device model's 4K context room for the instructions and the answer.
    static let textLimit = 8_000
    /// The queue holds a payload of 32 KB at most, JSON and all.
    static let byteLimit = 24_000

    let text: String
    let sourceURL: String?

    init(text: String, sourceURL: URL? = nil) {
        var cut = String(String.UnicodeScalarView(text.unicodeScalars.prefix(Self.textLimit)))
        while cut.utf8.count > Self.byteLimit { cut.removeLast() }
        self.text = cut
        self.sourceURL = sourceURL.flatMap { url in
            guard ["http", "https"].contains(url.scheme?.lowercased()), url.absoluteString.count <= 2048 else { return nil }
            return url.absoluteString
        }
    }

    enum CodingKeys: String, CodingKey { case text, sourceURL = "source_url" }
}

/// The model's answer, shaped by guided generation. Never saved as is: `StructuredRecipe` trims it to what a meal holds.
@Generable(description: "A dinner recipe read from text captured from a photo, a PDF or a social media post")
struct GeneratedRecipe: Equatable {
    @Guide(description: "The dish's name, a few words, in normal capitalization")
    var name: String

    @Guide(description: "How many people the recipe serves, or 0 if the text doesn't say", .range(0...50))
    var servings: Int

    @Guide(description: "Each ingredient on its own line, with its amount as the text gives it, like \"2 lb ground beef\"",
           .maximumCount(60))
    var ingredients: [String]

    @Guide(description: "The cooking steps in order, one step per item, without numbers", .maximumCount(50))
    var steps: [String]

    @Guide(description: "Things to start well before cooking, only if the recipe needs them: thawing, marinating, soaking, chilling overnight, starting a slow cooker",
           .maximumCount(10))
    var prepSteps: [GeneratedPrepStep]
}

@Generable(description: "Something to do ahead of dinner")
struct GeneratedPrepStep: Equatable {
    @Guide(description: "A short instruction, like \"Marinate the chicken\"")
    var step: String

    @Guide(description: "How many hours before dinner to start it", .range(1...48))
    var hoursAhead: Int
}

/// A `recipe` job's result: what every device reads back from the queue, within the limits a meal has.
struct StructuredRecipe: Codable, Equatable, Sendable {
    /// Under the queue's 32 KB result cap.
    static let byteLimit = 30_000

    var name: String
    var servings: Int?
    var ingredients: [String]
    var steps: [String]
    var prepSteps: [PrepStep]

    init(name: String, servings: Int?, ingredients: [String], steps: [String], prepSteps: [PrepStep]) {
        self.name = name
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.prepSteps = prepSteps
    }

    init(_ generated: GeneratedRecipe) {
        name = RecipeImport.clamped(Self.tidy(generated.name), to: 80)
        servings = (1...50).contains(generated.servings) ? generated.servings : nil
        ingredients = Array(generated.ingredients.map(Self.tidy).filter { !$0.isEmpty }
            .prefix(RecipeTextParser.ingredientLimit)).map { RecipeImport.clamped($0, to: 200) }
        steps = Array(generated.steps.map(Self.tidy).filter { !$0.isEmpty }.prefix(50)).map { RecipeImport.clamped($0, to: 2000) }
        prepSteps = Array(generated.prepSteps.compactMap { prep -> PrepStep? in
            let step = RecipeImport.clamped(Self.tidy(prep.step), to: 120)
            return step.isEmpty ? nil : PrepStep(step: step, leadHours: min(max(prep.hoursAhead, 1), 48))
        }.prefix(10))
    }

    var isEmpty: Bool { name.isEmpty && ingredients.isEmpty && steps.isEmpty }

    /// As the job's result; the last steps go if it's too big for the queue.
    func encoded() throws -> Data {
        var recipe = self
        var data = try JSONEncoder().encode(recipe)
        while data.count > Self.byteLimit, !recipe.steps.isEmpty {
            recipe.steps.removeLast()
            data = try JSONEncoder().encode(recipe)
        }
        return data
    }

    /// The same draft a plain read makes: amounts split off and scaled to the family once.
    func draft(householdSize: Int) -> MealDraft {
        let capture = RecipeTextParser.Capture(name: name.isEmpty ? nil : name, servings: servings,
                                               ingredients: ingredients.compactMap(IngredientParser.parseLine), steps: steps)
        var draft = capture.draft(householdSize: householdSize)
        draft.prepLines = prepSteps.map { MealDraft.PrepLine(step: $0.step, leadHours: $0.leadHours) }
        return draft
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Runs a `recipe` job on a capable device.
enum RecipeStructuring {
    /// Nothing about the family: the model only ever sees the recipe.
    static let instructions = """
        You read recipes. The text was captured from a photo, a PDF or a social media post, so it may include unrelated \
        words: app menus, ratings, ads, comments, hashtags or page numbers. Leave those out. Use only what the text says: \
        never add an ingredient, an amount or a step that isn't there. Keep each ingredient's amount as written. Leave \
        out nutrition information.
        """

    static func handle(_ payload: Data, _ ai: AIService) async -> AIJobOutcome {
        guard let job = try? JSONDecoder().decode(RecipeJobPayload.self, from: payload), !job.text.isEmpty else {
            return .failed("unreadable payload")
        }
        let outcome = await ai.generate(GeneratedRecipe.self, instructions: instructions,
                                        prompt: "Read this recipe:\n\n\(job.text)")
        if case .done(let generated) = outcome, StructuredRecipe(generated).isEmpty { return .failed("empty recipe") }
        return outcome.jobOutcome { try StructuredRecipe($0).encoded() }
    }
}
