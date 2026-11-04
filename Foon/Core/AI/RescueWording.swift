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
/// friendlier line for each idea. It only rephrases the code line, which stays on screen with the facts (age, time,
/// freezer date). The model sees each idea's title, kind and code line and tonight's time, never allergies, members
/// or who's home (CLAUDE.md rule 4).
enum RescueWording {
    /// Fits one line of a row's caption on an iPhone.
    static let maxLength = 70

    static func instructions(language: Locale.Language = Locale.current.language) -> String {
        let code = language.languageCode?.identifier ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return """
            You help a family pick something quick for dinner tonight. For each idea, rephrase its line in a \
            warm, brief way, under 60 characters. Talk about the food, never about whoever cooks it. Use only \
            what the idea says: never add an ingredient, a time, an age, a date or any number. Never mention \
            nutrition, calories or health. Answer in \(name) (\(language.minimalIdentifier)).
            """
    }

    static func prompt(_ ideas: [TonightRescue.Idea], minutes: Int) -> String {
        let lines = ideas.enumerated().map { index, idea in
            "\(index + 1). \(idea.title) (\(kindName(idea.kind))): \(idea.why)"
        }
        return (["There are about \(minutes) minutes to get dinner on the table tonight. The ideas:"] + lines)
            .joined(separator: "\n")
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

    /// What an answer was for: the ideas in order, each with the code line it rephrased, so an idea whose facts changed
    /// (a backup dinner no longer "everything's in") is a different draw.
    static func draw(_ ideas: [TonightRescue.Idea]) -> [String] {
        ideas.map { "\($0.id)\n\($0.why)" }
    }

    static func word(_ ideas: [TonightRescue.Idea], minutes: Int, language: Locale.Language,
                     _ ai: AIService) async -> [String: String] {
        let outcome = await ai.generate(GeneratedRescueWording.self, instructions: instructions(language: language),
                                        prompt: prompt(ideas, minutes: minutes))
        guard case .done(let answer) = outcome else { return [:] }
        return wording(answer.lines, for: ideas)
    }

    /// No digit, so it can't invent an age or a time; one line, so the row stays tidy.
    private static func validLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              !trimmed.contains(where: { $0.isNumber || $0.isNewline }) else { return nil }
        return trimmed
    }

    private static func kindName(_ kind: TonightRescue.Idea.Kind) -> String {
        switch kind {
        case .leftovers: "leftovers"
        case .freezer: "from the freezer"
        case .backup: "backup dinner"
        case .quickDish: "quick dish"
        case .quickPick: "quick pick"
        }
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
    func word(_ ideas: [TonightRescue.Idea], minutes: Int, language: Locale.Language = Locale.current.language) async {
        let draw = RescueWording.draw(ideas)
        guard !ideas.isEmpty, answers[draw] == nil, ai.canRun else { return }
        let lines = await RescueWording.word(ideas, minutes: minutes, language: language, ai)
        guard !Task.isCancelled else { return }
        answers[draw] = lines
    }
}
