import Foundation

/// The badges a planned night's card carries. Allergy flags name only who's home that night, and count the
/// meal's sides, as the shopping list does; the first prep step reminds what to start ahead.
enum NightBadges {
    static func badges(meal: LibraryMeal, library: [LibraryMeal], allergies: [MemberAllergies],
                       home: Set<UUID>) -> [DayCardModel.Badge] {
        let athome = allergies.filter { home.contains($0.memberID) }
        let flags = AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name),
                                         members: athome)
        let prep = meal.prepSteps.first.map { step in
            DayCardModel.Badge.prep([step.step, MealText.leadTime(hours: step.leadHours)].compactMap { $0 }
                .joined(separator: " · "))
        }
        return flags.map { .allergy($0.summary) } + (prep.map { [$0] } ?? [])
    }
}
