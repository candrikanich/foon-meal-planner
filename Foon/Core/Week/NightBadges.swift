import Foundation

/// The badges a planned night's card carries. Allergy flags name only who's home that night, and count the
/// meal's sides, as the shopping list does. Then what the dish usually uses that the kitchen doesn't have, when to start
/// cooking, and the first prep step, which reminds what to start ahead. A time to start replaces the slow cooker's step:
/// the two would be the same instruction, or conflict when the dish has its own time.
enum NightBadges {
    static func badges(meal: LibraryMeal, library: [LibraryMeal], allergies: [MemberAllergies], home: Set<UUID>,
                       settings: HouseholdSettings = HouseholdSettings(), start: StartCooking? = nil) -> [DayCardModel.Badge] {
        let athome = allergies.filter { home.contains($0.memberID) }
        let flags = AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name),
                                         members: athome)
        let prep = meal.prepSteps.first { step in
            start == nil || !DishTraits(name: step.step).equipment.contains(.slowCooker)
        }.map { step in
            DayCardModel.Badge.prep([step.step, MealText.leadTime(hours: step.leadHours)].compactMap { $0 }
                .joined(separator: " · "))
        }
        return flags.map { .allergy($0.summary) }
            + settings.missingEquipment(for: meal).map { .equipment($0.usuallyUsesText) }
            + (start.map { [.startCooking($0.text())] } ?? [])
            + (prep.map { [$0] } ?? [])
    }
}
