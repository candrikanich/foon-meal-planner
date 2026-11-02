import Foundation

/// A member's current verdict on a dish: their latest reaction to it (`meal_verdicts`).
struct MealVerdict: Equatable, Sendable, Decodable {
    let mealID: UUID
    let memberID: UUID
    let kind: ReactionKind
    let reactedOn: CalendarDay

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case memberID = "member_id"
        case kind = "reaction"
        case reactedOn = "reacted_on"
    }
}

/// How often anyone rated a dish favorite or good, ever (`meal_likes`).
struct MealLikes: Equatable, Sendable, Decodable {
    let mealID: UUID
    let likes: Int

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case likes
    }
}

/// A comment on a dish, from `meal_comments`. A hidden one only reaches planners, marked, so they can bring it back.
/// The server enforces that: its text moves out of `reactions` into a table only planners can read.
struct MealComment: Identifiable, Equatable, Sendable, Decodable {
    /// The reaction it's part of.
    let id: UUID
    let mealID: UUID
    let memberID: UUID
    let text: String
    let dinnerOn: CalendarDay
    var hidden: Bool

    private enum CodingKeys: String, CodingKey {
        case id, hidden
        case mealID = "meal_id"
        case memberID = "member_id"
        case text = "comment"
        case dinnerOn = "dinner_on"
    }
}

/// What the family's reactions mean for planning and the library (docs/spec.md → After-dinner loop). Pure.
/// - Favorite: pinned to that person, a boost on their home nights.
/// - Tired of it: a snooze, out of suggestions for a few weeks after that dinner.
/// - Not for me: lasting. One means only nights that person is away; two retire the dish (the server does that).
struct ReactionSummary: Equatable, Sendable {
    static let snoozeDays = 21

    var verdicts: [MealVerdict] = []
    var likes: [UUID: Int] = [:]

    init(verdicts: [MealVerdict] = [], likes: [MealLikes] = []) {
        self.verdicts = verdicts
        self.likes = Dictionary(likes.map { ($0.mealID, $0.likes) }, uniquingKeysWith: +)
    }

    /// Meal id → member id → 1 for each member whose current verdict is not for me.
    var notForMe: [UUID: [UUID: Int]] {
        verdicts.filter { $0.kind == .notForMe }
            .reduce(into: [:]) { map, verdict in map[verdict.mealID, default: [:]][verdict.memberID] = 1 }
    }

    /// Member id → the dishes that are their favorite now.
    var favorites: [UUID: Set<UUID>] {
        verdicts.filter { $0.kind == .favorite }
            .reduce(into: [:]) { map, verdict in map[verdict.memberID, default: []].insert(verdict.mealID) }
    }

    /// Dishes someone is tired of, until a few weeks after that dinner.
    func snoozed(today: CalendarDay) -> Set<UUID> {
        Set(verdicts.filter { $0.kind == .tiredOfIt && today < $0.reactedOn.adding(days: Self.snoozeDays) }.map(\.mealID))
    }

    func favoriteCount(_ mealID: UUID) -> Int {
        verdicts.count { $0.mealID == mealID && $0.kind == .favorite }
    }

    func verdicts(for mealID: UUID) -> [MealVerdict] {
        verdicts.filter { $0.mealID == mealID }
    }
}
