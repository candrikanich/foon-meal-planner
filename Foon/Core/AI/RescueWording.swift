import Foundation
import FoundationModels
import Observation

/// The model's answer: one line per rescue idea, in the order they were given.
@Generable(description: "Friendly lines for tonight's dinner ideas, one per idea, in the order the ideas were given")
struct GeneratedRescueWording: Equatable {
    @Guide(description: "One short, warm line per idea, in the same order as the ideas, without any numbers",
           .maximumCount(6))
    var lines: [String]
}

/// AI wording for the Tonight rescue (docs/spec.md → Tonight rescue): on a device that can run the model, a
/// friendlier line for each idea. The model gets each idea's name and a few words about its kind and reason, built
/// here and never from the code line: no names, days, ages or times, and no allergies or who's home (CLAUDE.md rule 4).
/// A line with a digit keeps the code line, and the facts always show beneath.
enum RescueWording {
    /// Fits one line of a row's caption on an iPhone.
    static let maxLength = 70

    static func instructions(language: Locale.Language = Locale.current.language) -> String {
        let code = language.languageCode?.identifier ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return """
            You help a family pick something quick for dinner tonight. Each idea has the dish's name and a few \
            words about it. For each idea, write one warm, brief line about the food, under 60 characters. Talk \
            about the food, never about whoever cooks it. Use only what the idea says: never add an ingredient, a \
            time, an age, a day, a date or any number. Never mention nutrition, calories or health. Answer in \
            \(name) (\(language.minimalIdentifier)).
            """
    }

    static func prompt(_ ideas: [TonightRescue.Idea]) -> String {
        let lines = ideas.enumerated().map { index, idea in "\(index + 1). \(idea.title): \(hint(idea))" }
        return (["Tonight's dinner ideas:"] + lines).joined(separator: "\n")
    }

    /// What the model reads about an idea, from its kind and reason, never from `why`.
    static func hint(_ idea: TonightRescue.Idea) -> String {
        switch idea.kind {
        case .leftovers: "leftovers in the fridge"
        case .freezer: "a homemade dinner from the freezer"
        case .backup: idea.everythingIn ? "a backup dinner, everything's in" : "a backup dinner"
        case .quickDish: ["a quick dish", idea.reason.flatMap(reasonHint)].compactMap { $0 }.joined(separator: ", ")
        case .quickPick(let pick): pickHint(pick)
        }
    }

    /// Never the name a reason carries ("Nora's favorite"), a day count, or a tradition's name (often a weekday).
    static func reasonHint(_ reason: PlanReason) -> String? {
        switch reason {
        case .request: "someone asked for it"
        case .favorite: "a family favorite"
        case .somethingNew: "something new to try"
        case .quickForRushedNight: "quick for a rushed night"
        case .usesWhatsOnHand: "uses what's on hand"
        case .notHadIn: "haven't had it in a while"
        case .dueForATurn: "due for a turn"
        case .familyLikesIt: "the family likes it"
        case .bigBatch: "makes plenty"
        case .tradition: "a family tradition"
        case .leftoversAfterBigBatch, .leftoversNight, .takeoutOnBusiestNight, .traditionSatOut, .nobodyHome,
             .nothingFits: nil
        }
    }

    private static func pickHint(_ pick: QuickPick) -> String {
        switch pick {
        case .takeout: "takeout, nothing to cook"
        case .freezerRaid: "whatever's in the freezer"
        case .fendForYourselves: "everyone makes their own"
        case .eatOut: "eating out, nobody cooks or cleans up"
        case .leftovers: "whatever's in the fridge"
        }
    }

    /// Each line as shown, or nil where that idea keeps its code line. The wrong number of lines means every idea does.
    static func validated(_ lines: [String], count: Int) -> [String?] {
        guard lines.count == count else { return Array(repeating: nil, count: count) }
        return lines.map(validLine)
    }

    /// The lines that passed, by idea id.
    static func wording(_ lines: [String], for ideas: [TonightRescue.Idea]) -> [String: String] {
        let pairs = zip(ideas, validated(lines, count: ideas.count))
            .compactMap { idea, line in line.map { (idea.id, $0) } }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// What an answer was for: the ideas in order, each with its code line, so an idea whose facts changed (a backup
    /// dinner no longer "everything's in") is a different draw.
    static func draw(_ ideas: [TonightRescue.Idea]) -> [String] {
        ideas.map { "\($0.id)\n\($0.why)" }
    }

    static func word(_ ideas: [TonightRescue.Idea], language: Locale.Language,
                     _ ai: AIService) async -> [String: String] {
        let outcome = await ai.generate(GeneratedRescueWording.self, instructions: instructions(language: language),
                                        prompt: prompt(ideas))
        guard case .done(let answer) = outcome else { return [:] }
        return wording(answer.lines, for: ideas)
    }

    /// A digit is the likeliest made-up fact (an age, a time), so that line keeps the code line; a spelled-out one
    /// ("three days old") gets through, which is why the facts show beneath. One line, so the row stays tidy.
    private static func validLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              !trimmed.contains(where: { $0.isNumber || $0.isNewline }) else { return nil }
        return trimmed
    }
}

/// The rescue sheet's AI lines, one answer per draw. The code lines show first; an answer appears only on the draw it
/// was for, so redrawing never shows another draw's lines, and drawing back to one already answered doesn't ask again.
@MainActor @Observable
final class RescueWordingStore {
    private let ai: AIService
    private var answers: [[String]: [String: String]] = [:]

    init(ai: AIService) {
        self.ai = ai
    }

    func lines(for ideas: [TonightRescue.Idea]) -> [String: String] {
        answers[RescueWording.draw(ideas)] ?? [:]
    }

    /// Cancelled (the draw changed, or the sheet closed), nothing's kept, so the draw can be asked again later. A
    /// failure is kept as no lines, so it isn't retried while the sheet's open.
    func word(_ ideas: [TonightRescue.Idea], language: Locale.Language = Locale.current.language) async {
        let draw = RescueWording.draw(ideas)
        guard !ideas.isEmpty, answers[draw] == nil, ai.canRun else { return }
        let lines = await RescueWording.word(ideas, language: language, ai)
        guard !Task.isCancelled else { return }
        answers[draw] = lines
    }
}
