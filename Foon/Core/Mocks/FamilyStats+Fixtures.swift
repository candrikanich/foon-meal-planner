import Foundation

extension FamilyStats {
    static let sample = FamilyStats(dinners: 12, dishes: 10, ideas: 3, cookedByOthers: 4, atTable: 9, newDishes: 2,
                                    weeksPlanned: 4)
}

extension TriedNewDishes {
    /// A month for previews: the youngest tried three new dishes, the second one.
    static func samples(for members: [Member] = Member.sampleFamily) -> [TriedNewDishes] {
        zip(Array(members.suffix(1)) + Array(members.dropFirst().prefix(1)), [3, 1]).map {
            TriedNewDishes(memberID: $0.id, dishes: $1)
        }
    }
}
