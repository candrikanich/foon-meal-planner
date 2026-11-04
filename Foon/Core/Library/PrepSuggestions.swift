import Foundation

/// Prep steps a dish looks like it needs, offered in its editor and only saved if someone taps one (docs/spec.md → Each meal
/// carries). By keyword, never by AI: it's the path every device has, and what's offered when no AI result comes. A guess costs
/// a tap to ignore, so it can over-match; a kind the dish already has isn't offered.
enum PrepSuggestions {
    static func suggestions(name: String, ingredients: [String], steps: String, tags: Set<MealTag>, existing: [String],
                            keepsMeatFrozen: Bool) -> [PrepStep] {
        let have = Set(existing.map(PrepKind.init(step:)))
        let dish = [name] + ingredients
        let everything = (dish + [steps]).joined(separator: "\n").lowercased()
        let overnight = (dish + sentences(steps)).filter { $0.lowercased().contains("overnight") }
        var found: [PrepStep] = []
        if keepsMeatFrozen, !have.contains(.thaw),
           tags.contains(.thawFirst) || PrepKind(step: steps) == .thaw || FoodRuleMatcher.looksLikeMeat(dish) {
            found.append(PrepStep(step: String(localized: "Move the meat to the fridge to thaw", comment: "Suggested prep step"),
                                  leadHours: 24))
        }
        if !have.contains(.marinate), PrepKind.marinateWords.contains(where: everything.contains) {
            let isOvernight = overnight.contains { PrepKind(step: $0) == .marinate }
            found.append(PrepStep(step: String(localized: "Marinate", comment: "Suggested prep step"),
                                  leadHours: isOvernight ? 12 : 4))
        }
        if !have.contains(.slowCooker),
           DishTraits(name: name, tags: Array(tags)).equipment.contains(.slowCooker) || PrepKind.slowCookerWords.contains(where: everything.contains) {
            found.append(PrepStep(step: String(localized: "Start the slow cooker", comment: "Suggested prep step"), leadHours: 8))
        }
        // Soaking beans, chilling a dough: anything else left overnight starts the evening before.
        let hasOvernightStep = existing.contains { ["overnight", "night before"].contains(where: $0.lowercased().contains) }
        if !hasOvernightStep, overnight.contains(where: { PrepKind(step: $0) == .other }) {
            found.append(PrepStep(step: String(localized: "Start the night before", comment: "Suggested prep step"),
                                  leadHours: 24))
        }
        return found
    }

    private static func sentences(_ steps: String) -> [String] {
        steps.split(whereSeparator: \.isNewline).flatMap { $0.split(separator: ". ") }.map(String.init)
    }
}
