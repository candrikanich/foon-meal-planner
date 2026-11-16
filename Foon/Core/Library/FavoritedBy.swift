import Foundation

/// Who has a dish as a favorite, and how the Library says so (docs/spec.md → Library screen). Pure.
/// About the dish, never the cook: "Nora's favorite", not "Nora cooks it".
enum FavoritedBy {
    /// Meal id → the members whose current verdict on it is favorite, in the household's member order.
    /// A later not-for-me or tired-of-it replaces an earlier favorite, as it does everywhere else. Removed members
    /// and kids who eat separately (whose ratings stop counting) are left out; someone away still has favorites.
    static func byMeal(verdicts: [MealVerdict], members: [Member]) -> [UUID: [Member]] {
        let counted = members.filter { $0.status != .removed && !$0.eatsSeparately }
        let countedIDs = Set(counted.map(\.id))
        struct Key: Hashable { let mealID: UUID, memberID: UUID }
        var latest: [Key: MealVerdict] = [:]
        for verdict in verdicts where countedIDs.contains(verdict.memberID) {
            let key = Key(mealID: verdict.mealID, memberID: verdict.memberID)
            if let seen = latest[key], verdict.reactedOn < seen.reactedOn { continue }
            latest[key] = verdict
        }
        let favoriters = latest.values.filter { $0.kind == .favorite }
        let membersByMeal = Dictionary(grouping: favoriters, by: \.mealID).mapValues { Set($0.map(\.memberID)) }
        return membersByMeal.mapValues { ids in counted.filter { ids.contains($0.id) } }
    }

    /// "Nora's favorite", "Nora and Ben's favorite", "Favorite of 3"; nil when no one has it as a favorite.
    static func text(_ favoriters: [Member], locale: Locale = .current) -> String? {
        switch favoriters.count {
        case 0:
            return nil
        case 1, 2:
            let names = favoriters.map(\.firstName).formatted(.list(type: .and).locale(locale))
            return String(localized: "\(names)'s favorite",
                          comment: "Library row: one person's, or two people's, favorite dish; names already joined")
        default:
            return String(localized: "Favorite of \(favoriters.count)",
                          comment: "Library row: a dish three or more family members have as a favorite")
        }
    }
}
