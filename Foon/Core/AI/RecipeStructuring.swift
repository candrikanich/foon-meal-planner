import Foundation
import FoundationModels

/// What the model reads for a captured recipe, here or (from a device that can't run it) through the household's queue: the
/// recipe lines the plain read found and where they came from, nothing else. Never the raw text with the screen around it, and
/// no allergies, members or household size (CLAUDE.md rule 4): scaling and allergy checks happen on the device showing it.
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

    /// The parsed lines only: the title, the servings, each ingredient as read (before scaling) and each step. Nil when the
    /// plain read found no ingredients or steps, so nothing is sent.
    init?(_ capture: RecipeTextParser.Capture, sourceURL: URL? = nil) {
        guard !capture.ingredients.isEmpty || !capture.steps.isEmpty else { return nil }
        var lines: [String] = []
        if let name = capture.name { lines.append(name) }
        if let servings = capture.servings { lines.append("Serves \(servings)") }
        if !capture.ingredients.isEmpty {
            lines.append("Ingredients:")
            lines += capture.ingredients.map { [$0.quantity, $0.name].compactMap { $0 }.joined(separator: " ") }
        }
        if !capture.steps.isEmpty {
            lines.append("Steps:")
            lines += capture.steps
        }
        self.init(text: lines.joined(separator: "\n"), sourceURL: sourceURL)
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

/// A tidied recipe, within the limits a meal has. Every way in (the model's answer, a job's result read back from the queue)
/// goes through the same trimming, so a result written by an older app or a tampered row can't exceed them.
struct StructuredRecipe: Codable, Equatable, Sendable {
    /// Under the queue's 32 KB result cap.
    static let byteLimit = 30_000

    let name: String
    let servings: Int?
    let ingredients: [String]
    private(set) var steps: [String]
    /// Offered as suggestions to tap, never saved on their own.
    let prepSteps: [PrepStep]

    init(name: String, servings: Int?, ingredients: [String], steps: [String], prepSteps: [PrepStep]) {
        self.name = RecipeImport.clamped(Self.tidy(name), to: 80)
        self.servings = servings.flatMap { (1...50).contains($0) ? $0 : nil }
        self.ingredients = Array(ingredients.map(Self.tidy).filter { !$0.isEmpty }
            .prefix(RecipeTextParser.ingredientLimit)).map { RecipeImport.clamped($0, to: 200) }
        self.steps = Array(steps.map(Self.tidy).filter { !$0.isEmpty }.prefix(50)).map { RecipeImport.clamped($0, to: 2000) }
        self.prepSteps = Array(prepSteps.compactMap { prep -> PrepStep? in
            let step = RecipeImport.clamped(Self.tidy(prep.step), to: 120)
            return step.isEmpty ? nil : PrepStep(step: step, leadHours: prep.leadHours.map { min(max($0, 1), 48) })
        }.prefix(10))
    }

    init(_ generated: GeneratedRecipe) {
        self.init(name: generated.name, servings: generated.servings, ingredients: generated.ingredients,
                  steps: generated.steps,
                  prepSteps: generated.prepSteps.map { PrepStep(step: $0.step, leadHours: $0.hoursAhead) })
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  servings: try container.decodeIfPresent(Int.self, forKey: .servings),
                  ingredients: try container.decode([String].self, forKey: .ingredients),
                  steps: try container.decode([String].self, forKey: .steps),
                  prepSteps: try container.decodeIfPresent([PrepStep].self, forKey: .prepSteps) ?? [])
    }

    private enum CodingKeys: String, CodingKey { case name, servings, ingredients, steps, prepSteps }

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

    /// The same draft a plain read makes: amounts split off and scaled to the family once. No prep steps: those are offered.
    func draft(householdSize: Int) -> MealDraft {
        RecipeTextParser.Capture(name: name.isEmpty ? nil : name, servings: servings,
                                 ingredients: ingredients.compactMap(IngredientParser.parseLine), steps: steps)
            .draft(householdSize: householdSize)
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Runs the model over a captured recipe: on the device that captured it when it can, or for a `recipe` job from the queue.
enum RecipeStructuring {
    /// Nothing about the family: the model only ever sees the recipe.
    static let instructions = """
        You read recipes. The text was captured from a photo, a PDF or a social media post, so it may include unrelated \
        words: app menus, ratings, ads, comments, hashtags or page numbers. Leave those out. Use only what the text says: \
        never add an ingredient, an amount or a step that isn't there. Keep each ingredient's amount as written. Leave \
        out nutrition information.
        """

    static func structure(_ payload: RecipeJobPayload, _ ai: AIService) async -> AIOutcome<StructuredRecipe> {
        guard !payload.text.isEmpty else { return .failed }
        let outcome = await ai.generate(GeneratedRecipe.self, instructions: instructions,
                                        prompt: "Read this recipe:\n\n\(payload.text)")
        switch outcome {
        case .done(let generated):
            let recipe = StructuredRecipe(generated)
            return recipe.isEmpty ? .failed : .done(recipe)
        case .unavailable: return .unavailable
        case .timedOut: return .timedOut
        case .failed: return .failed
        }
    }

    static func handle(_ payload: Data, _ ai: AIService) async -> AIJobOutcome {
        guard let job = try? JSONDecoder().decode(RecipeJobPayload.self, from: payload), !job.text.isEmpty else {
            return .failed("unreadable payload")
        }
        let outcome = await structure(job, ai)
        if case .failed = outcome { return .failed("no recipe") }
        return outcome.jobOutcome { try $0.encoded() }
    }
}
