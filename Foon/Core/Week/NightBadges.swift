import Foundation

/// The badges a planned night's card carries. Allergy flags name only who's home that night, and count the
/// meal's sides, as the shopping list does. Then what the dish needs that the kitchen doesn't have, when to start
/// cooking, and the first prep step, which reminds what to start ahead unless the time to start already says it.
enum NightBadges {
    static func badges(meal: LibraryMeal, library: [LibraryMeal], allergies: [MemberAllergies], home: Set<UUID>,
                       settings: HouseholdSettings = HouseholdSettings(), start: StartCooking? = nil) -> [DayCardModel.Badge] {
        let athome = allergies.filter { home.contains($0.memberID) }
        let flags = AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name),
                                         members: athome)
        let saidByStart = start != nil && meal.prepSteps.first?.leadHours.map { $0 * 60 } == start?.cookMinutes
        let prep = meal.prepSteps.first.flatMap { saidByStart ? nil : $0 }.map { step in
            DayCardModel.Badge.prep([step.step, MealText.leadTime(hours: step.leadHours)].compactMap { $0 }
                .joined(separator: " · "))
        }
        return flags.map { .allergy($0.summary) }
            + settings.missingEquipment(for: meal).map { .equipment($0.needsText) }
            + (start.map { [.startCooking($0.text())] } ?? [])
            + (prep.map { [$0] } ?? [])
    }
}
