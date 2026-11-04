import Foundation

/// How many dishes someone tried for the first time in a range, from `tried_new` (docs/spec.md → Success metrics:
/// shown to families). Any reaction counts, not for me included: it celebrates trying, not liking.
struct TriedNewDishes: Decodable, Equatable, Sendable {
    let memberID: UUID
    let dishes: Int

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case dishes
    }
}

/// Picky-eater wins on a member's own profile: warm, about trying, and never a comparison.
enum TriedNew {
    /// "Tried 3 new dishes this month", or nil at zero, so nobody's profile says they didn't try anything.
    static func monthTitle(for memberID: UUID, in tries: [TriedNewDishes]) -> String? {
        guard let count = tries.first(where: { $0.memberID == memberID })?.dishes, count > 0 else { return nil }
        return String(localized: "Tried \(count) new dishes this month",
                      comment: "Member profile: dishes this person tried for the first time this month; about trying")
    }
}
