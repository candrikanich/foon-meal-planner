import Foundation

extension YearRecapFacts {
    /// A good year: most nights at the table, three standbys, three cooks, and the youngest two trying new things.
    static func sample(members: [Member] = Member.sampleFamily) -> YearRecapFacts {
        YearRecapFacts(
            logged: 214,
            stats: FamilyStats(dinners: 230, dishes: 196, ideas: 41, cookedByOthers: 38, atTable: 188, newDishes: 27,
                               weeksPlanned: 44),
            topDishes: [
                Dish(id: UUID(), name: "Taco night", times: 31),
                Dish(id: UUID(), name: "Sheet-pan chicken", times: 18),
                Dish(id: UUID(), name: "Pot roast", times: 11)
            ],
            cooks: members.prefix(3).map(\.id),
            tried: members.suffix(2).map(\.id)
        )
    }
}
