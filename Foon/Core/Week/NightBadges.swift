import Foundation

/// The badges a planned night's card carries. Allergy flags name only who's home that night, and count the
/// meal's sides, as the shopping list does. Then a food rule it looks to break, on a night still ahead, however it got
/// there (a request, a pin, the planner's own pick); it never blocks anything. Then what the dish usually uses that the kitchen doesn't have, when to start
/// cooking, and the first prep step, which reminds what to start ahead. A time to start replaces the slow cooker's step:
/// the two would be the same instruction, or conflict when the dish has its own time.
enum NightBadges {
    static func badges(meal: LibraryMeal, library: [LibraryMeal], allergies: [MemberAllergies], home: Set<UUID>,
                       settings: HouseholdSettings = HouseholdSettings(), start: StartCooking? = nil,
                       alreadyCooked: Bool = false, ruleDay: CalendarDay? = nil) -> [DayCardModel.Badge] {
        let athome = allergies.filter { home.contains($0.memberID) }
        let flags = AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name),
                                         members: athome)
        let rules: [DayCardModel.Badge] = ruleDay.map { day in
            FoodRuleMatcher.broken(by: meal, on: day, rules: settings.foodRules, library: library)
                .map { .foodRule($0.looksLikeText) }
        } ?? []
        // Out of the freezer or left over: allergies and rules still count, but there's nothing to start or cook it with.
        guard !alreadyCooked else { return flags.map { .allergy($0.summary) } + rules }
        let prep = meal.prepSteps.first { step in
            start == nil || !DishTraits(name: step.step).equipment.contains(.slowCooker)
        }.map { step in
            DayCardModel.Badge.prep([step.step, MealText.leadTime(hours: step.leadHours)].compactMap { $0 }
                .joined(separator: " · "))
        }
        return flags.map { .allergy($0.summary) }
            + rules
            + settings.missingEquipment(for: meal).map { .equipment($0.usuallyUsesText) }
            + (start.map { [.startCooking($0.text())] } ?? [])
            + (prep.map { [$0] } ?? [])
    }
}
