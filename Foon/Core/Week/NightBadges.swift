import Foundation

/// The badges a planned night's card carries. Allergy flags name only who's home that night, and count the
/// meal's sides, as the shopping list does. Then a food rule it looks to break, on a night still ahead, however it got
/// there (a request, a pin, the planner's own pick); it never blocks anything. Then what the dish usually uses that the
/// kitchen doesn't have, when to start cooking, and the first prep step, which reminds what to start ahead. A time to start
/// replaces the slow cooker's step: the two would be the same instruction, or conflict when the dish has its own time.
enum NightBadges {
    /// What's said about a dish's allergies on a night: on its card, and in Swap and Plan it before it's chosen, so they
    /// can't disagree. `home` is `WeekNight.home`. A dish the library can't find (`nil`) says it couldn't be checked, once
    /// there's an answer: nothing while a load runs, and nothing if the allergies have been read and nobody home has any.
    /// Until they've been read, nobody knows that, so a failed load says so to everyone.
    static func allergyCheck(dish: LibraryMeal?, library: [LibraryMeal], allergies: [MemberAllergies], home: Set<UUID>,
                             lookup: LibraryLookup) -> AllergyCheck {
        let athome = allergies.filter { home.contains($0.memberID) }
        if let dish { return AllergyMatcher.check(meal: dish, library: library, members: athome) }
        if lookup == .loaded, !athome.contains(where: \.hasAllergies) { return AllergyCheck() }
        return AllergyCheck(note: FreezerStash.allergyUnknownNote(for: nil, isLoading: lookup == .loading))
    }

    /// A starter dish offered in Swap's search, for whoever's home that night.
    static func allergyCheck(catalog dish: CatalogDish, allergies: [MemberAllergies], home: Set<UUID>) -> AllergyCheck {
        AllergyMatcher.check(catalog: dish, members: allergies.filter { home.contains($0.memberID) })
    }

    static func allergyBadges(_ check: AllergyCheck) -> [DayCardModel.Badge] {
        check.flags.map { .allergy($0.summary) } + (check.note.map { [.allergyUnchecked($0)] } ?? [])
    }

    static func badges(meal: LibraryMeal, library: [LibraryMeal], allergies: [MemberAllergies], home: Set<UUID>,
                       settings: HouseholdSettings = HouseholdSettings(), start: StartCooking? = nil,
                       alreadyCooked: Bool = false, ruleDay: CalendarDay? = nil) -> [DayCardModel.Badge] {
        let allergyBadges = allergyBadges(allergyCheck(dish: meal, library: library, allergies: allergies, home: home,
                                                       lookup: .loaded))
        let rules: [DayCardModel.Badge] = ruleDay.map { day in
            FoodRuleMatcher.broken(by: meal, on: day, rules: settings.foodRules, library: library)
                .map { .foodRule($0.looksLikeText) }
        } ?? []
        // Out of the freezer or left over: allergies and rules still count, but there's nothing to start or cook it with.
        guard !alreadyCooked else { return allergyBadges + rules }
        let prep = meal.prepSteps.first { step in
            start == nil || !DishTraits(name: step.step).equipment.contains(.slowCooker)
        }.map { step in
            DayCardModel.Badge.prep([step.step, MealText.leadTime(hours: step.leadHours)].compactMap { $0 }
                .joined(separator: " · "))
        }
        return allergyBadges
            + rules
            + settings.missingEquipment(for: meal).map { .equipment($0.usuallyUsesText) }
            + (start.map { [.startCooking($0.text())] } ?? [])
            + (prep.map { [$0] } ?? [])
    }
}
