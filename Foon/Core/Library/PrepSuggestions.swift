import Foundation

/// Prep steps a dish looks like it needs, offered in its editor and only saved if someone taps one (docs/spec.md → Each meal
/// carries). By keyword, never by AI. A guess costs a tap to ignore, so it can over-match; a kind the dish already has isn't offered.
enum PrepSuggestions {
    static func suggestions(name: String, ingredients: [String], steps: String, tags: Set<MealTag>, existing: [String],
                            keepsMeatFrozen: Bool) -> [PrepStep] {
        let have = Set(existing.map(PrepKind.init(step:)))
        let dish = [name] + ingredients
        let everything = (dish + [steps]).joined(separator: "\n").lowercased()
        var found: [PrepStep] = []
        if keepsMeatFrozen, !have.contains(.thaw),
           tags.contains(.thawFirst) || PrepKind(step: steps) == .thaw || FoodRuleMatcher.looksLikeMeat(dish) {
            found.append(PrepStep(step: String(localized: "Move the meat to the fridge to thaw", comment: "Suggested prep step"),
                                  leadHours: 24))
        }
        if !have.contains(.marinate), PrepKind.marinateWords.contains(where: everything.contains) {
            found.append(PrepStep(step: String(localized: "Marinate", comment: "Suggested prep step"), leadHours: 4))
        }
        if !have.contains(.slowCooker),
           DishTraits(name: name, tags: Array(tags)).equipment.contains(.slowCooker) || PrepKind.slowCookerWords.contains(where: everything.contains) {
            found.append(PrepStep(step: String(localized: "Start the slow cooker", comment: "Suggested prep step"), leadHours: 8))
        }
        return found
    }
}
