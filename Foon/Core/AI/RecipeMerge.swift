import CryptoKit
import Foundation

/// A draft as it was first read, field by field, so a later AI result can tell what nobody's touched. Each field is a digest
/// of its text, read the way a saved meal comes back (trimmed, lowercased, step numbers dropped), so the same comparison
/// works on the review screen and on the meal after it's saved, on any phone, and no recipe text is kept for it. Prep steps
/// aren't here: AI ones are only ever offered (`RecipePrep`).
struct RecipeBaseline: Codable, Equatable, Sendable {
    /// Nil when the person gave the name (shared with it, or typed): theirs is never replaced.
    let name: String?
    let ingredients: String
    let steps: String

    init(_ draft: MealDraft, nameIsTheirs: Bool = false) {
        name = nameIsTheirs ? nil : Self.digest(Self.name(draft))
        ingredients = Self.digest(Self.ingredients(draft))
        steps = Self.digest(Self.steps(draft))
    }

    fileprivate static func name(_ draft: MealDraft) -> String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate static func ingredients(_ draft: MealDraft) -> String {
        draft.lines.compactMap { line in
            let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : "\(line.quantity.trimmingCharacters(in: .whitespacesAndNewlines))|\(name)"
        }.joined(separator: "\n").lowercased()
    }

    fileprivate static func steps(_ draft: MealDraft) -> String {
        draft.stepsText.split(whereSeparator: \.isNewline).map(MealDraft.withoutNumbering).filter { !$0.isEmpty }
            .joined(separator: "\n").lowercased()
    }

    fileprivate static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Puts an AI result into a draft: each field the person hasn't changed since the plain read takes the AI's version, and
/// everything they changed stays as they left it (docs/spec.md → Household AI queue).
enum RecipeMerge {
    /// The draft with the result in it, or nil when there's nothing to change.
    static func merged(_ current: MealDraft, baseline: RecipeBaseline, recipe: StructuredRecipe) -> MealDraft? {
        let tidy = recipe.draft(householdSize: current.servings)
        var merged = current
        if let name = baseline.name, !tidy.name.isEmpty, untouched(name, RecipeBaseline.name(current)) {
            merged.name = tidy.name
        }
        if !tidy.lines.isEmpty, untouched(baseline.ingredients, RecipeBaseline.ingredients(current)) {
            merged.lines = tidy.lines + allergenLinesOnlyIn(current.lines, missingFrom: tidy.lines)
        }
        if !tidy.stepsText.isEmpty, untouched(baseline.steps, RecipeBaseline.steps(current)) {
            merged.stepsText = tidy.stepsText
        }
        return same(merged, current) ? nil : merged
    }

    private static func untouched(_ baseline: String, _ current: String) -> Bool {
        baseline == RecipeBaseline.digest(current)
    }

    /// Allergy flags read ingredients, so a line from the plain read that names an allergen the model's lines don't is kept:
    /// a model that drops "peanuts" mustn't drop a flag.
    private static func allergenLinesOnlyIn(_ plain: [MealDraft.Line], missingFrom tidy: [MealDraft.Line]) -> [MealDraft.Line] {
        var covered = tidy.reduce(into: Set<Allergen>()) { $0.formUnion(AllergyMatcher.allergens(in: $1.name)) }
        return plain.filter { line in
            let allergens = AllergyMatcher.allergens(in: line.name)
            guard !allergens.isSubset(of: covered) else { return false }
            covered.formUnion(allergens)
            return true
        }
    }

    /// Line ids are new on every draft, so they don't count as a change.
    private static func same(_ a: MealDraft, _ b: MealDraft) -> Bool {
        a.name == b.name && a.stepsText == b.stepsText
            && a.lines.map { [$0.quantity, $0.name] } == b.lines.map { [$0.quantity, $0.name] }
    }
}

/// Prep steps to offer for a captured dish, each saved only if the planner taps it (docs/spec.md → Each meal carries): the AI
/// result's first, then the keyword ones (`PrepSuggestions`) of any kind it didn't cover. Without a result, just the keywords.
enum RecipePrep {
    static func offered(_ draft: MealDraft, ai: [PrepStep], keepsMeatFrozen: Bool) -> [PrepStep] {
        let have = draft.prepLines.map(\.step).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let haveKinds = Set(have.map(PrepKind.init(step:)))
        let haveSteps = Set(have.map { $0.lowercased() })
        var offered: [PrepStep] = []
        for step in ai where !haveSteps.contains(step.step.lowercased()) {
            let kind = PrepKind(step: step.step)
            // A thaw for a family that buys meat fresh isn't offered, as with the keywords.
            if kind == .thaw && !keepsMeatFrozen { continue }
            if kind != .other && (haveKinds.contains(kind) || offered.contains { PrepKind(step: $0.step) == kind }) { continue }
            offered.append(step)
        }
        let keywords = PrepSuggestions.suggestions(
            name: draft.name, ingredients: draft.lines.map(\.name), steps: draft.stepsText, tags: draft.tags,
            existing: have + offered.map(\.step), keepsMeatFrozen: keepsMeatFrozen
        )
        return offered + keywords
    }
}
