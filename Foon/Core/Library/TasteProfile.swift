import Foundation

/// What a member's profile says about their taste (docs/spec.md → Family tab): dishes, never cooks. Pure. Archived dishes
/// and ones this device can't name are left out; a retired dish stays, since that's still what they think of it. Tired of it
/// is a snooze that wears off, so it isn't here.
struct TasteProfile: Equatable, Sendable {
    struct Dish: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
    }

    struct Note: Identifiable, Equatable, Sendable {
        let id: UUID
        let dish: String
        let note: String
    }

    var favorites: [Dish] = []
    var ratherSkip: [Dish] = []
    var notes: [Note] = []

    var isEmpty: Bool { favorites.isEmpty && ratherSkip.isEmpty && notes.isEmpty }

    init(memberID: UUID, verdicts: [MealVerdict], notes: [ServingNote], meals: [LibraryMeal]) {
        let named = Dictionary(meals.filter { $0.status != .archived }.map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        func dishes(_ kind: ReactionKind) -> [Dish] {
            verdicts.filter { $0.memberID == memberID && $0.kind == kind }
                .compactMap { verdict in named[verdict.mealID].map { Dish(id: verdict.mealID, name: $0) } }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        favorites = dishes(.favorite)
        ratherSkip = dishes(.notForMe)
        self.notes = notes.filter { $0.memberID == memberID }
            .compactMap { note in named[note.mealID].map { Note(id: note.mealID, dish: $0, note: note.note) } }
            .sorted { $0.dish.localizedStandardCompare($1.dish) == .orderedAscending }
    }
}
