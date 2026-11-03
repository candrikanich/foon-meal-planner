import Foundation

extension WeekRecapFacts {
    /// A good week: two cooks from the family, a hit, and a favorite nobody's made in a while.
    static func sample(cooks members: [Member] = Member.sampleFamily) -> WeekRecapFacts {
        WeekRecapFacts(logged: 6, cooks: members.suffix(2).map(\.id),
                       topDish: Dish(id: UUID(), name: "Sheet-pan chicken"),
                       forgottenFavorite: Dish(id: UUID(), name: "Pot roast"))
    }
}

extension FamilyStats {
    /// One week of `sample`'s month.
    static let sampleWeek = FamilyStats(dinners: 6, dishes: 5, ideas: 2, cookedByOthers: 2, atTable: 5, newDishes: 1,
                                        weeksPlanned: 1)
}
