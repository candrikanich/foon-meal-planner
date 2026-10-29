import Foundation

/// How someone likes a dish served ("Nora: keep everything separate before mixing"), from `serving_notes`.
struct ServingNote: Equatable, Sendable, Decodable {
    let mealID: UUID
    let memberID: UUID
    let note: String

    static let maxLength = 120

    /// Length as the server counts it (code points), so a note of emoji that fits here fits there too.
    static func length(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case memberID = "member_id"
        case note
    }
}

/// Which notes show where (docs/spec.md → Meal detail): on a day card, only for people home that night, in the
/// family's order. Pure.
enum ServingNotes {
    /// "Nora: keep everything separate", for the given dish and the members home, in `members` order.
    static func lines(_ notes: [ServingNote], mealID: UUID, home: Set<UUID>, members: [Member]) -> [String] {
        let forDish = Dictionary(notes.filter { $0.mealID == mealID }.map { ($0.memberID, $0.note) },
                                 uniquingKeysWith: { first, _ in first })
        return members.compactMap { member in
            guard home.contains(member.id), let note = forDish[member.id] else { return nil }
            return String(localized: "serving-note.line", defaultValue: "\(member.firstName): \(note)",
                          comment: "A serving note on a day card: who, then how they like the dish")
        }
    }

    /// Who may write a member's note: themselves, or a parent (the server's rule too).
    static func canWrite(for member: Member, me: Member?, isParent: Bool) -> Bool {
        member.status != .removed && (isParent || member.id == me?.id)
    }
}
