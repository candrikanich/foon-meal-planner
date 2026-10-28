import Foundation
import Supabase

/// An item's standing note or brand preference ("Vanilla, not plain", "store brand"), shown wherever the
/// item appears: meals, lists, and store mode.
enum ItemNote {
    struct TooLong: Error {}

    /// Trimmed; blank means no note. Measured in code points, as Postgres does.
    static func cleaned(_ typed: String) throws(TooLong) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count <= 80 else { throw TooLong() }
        return trimmed
    }

}

/// What the item sheet shows and edits.
struct ItemDetails: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    var category: ItemCategory
    var note: String?
    var keepOnHand: Bool
}

/// Only the fields that changed: a member's note never sends a category the server would refuse.
struct ItemChanges: Equatable, Sendable, Encodable {
    /// `.some(nil)` clears the note.
    var note: String??
    var category: ItemCategory?

    var isEmpty: Bool { note == nil && category == nil }

    private enum CodingKeys: String, CodingKey { case note, category }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let note { try container.encode(note, forKey: .note) }
        if let category { try container.encode(category, forKey: .category) }
    }
}

struct ItemClient: Sendable {
    var update: @Sendable (_ itemID: UUID, _ changes: ItemChanges) async throws -> Void
    /// The household's item with this name, created if new (`ensure_item`). Needs a connection.
    var ensure: @Sendable (_ householdID: UUID, _ name: String, _ category: ItemCategory) async throws -> UUID
        = { _, _, _ in throw LibraryClientError.notAllowed }
}

extension ItemClient {
    static func live(_ client: SupabaseClient) -> ItemClient {
        ItemClient(update: { itemID, changes in
            // Row-level security turns a refused update into zero rows, not an error, so check.
            let updated: [UpdatedItem] = try await client.from("items")
                .update(changes)
                .eq("id", value: itemID)
                .select("id")
                .execute()
                .value
            guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
        }, ensure: { householdID, name, category in
            let item: UpdatedItem = try await client.rpc("ensure_item", params: EnsureItemParams(
                targetHousehold: householdID, itemName: name, itemCategory: category
            )).select("id").single().execute().value
            return item.id
        })
    }

    static let preview = ItemClient(update: { _, _ in }, ensure: { _, _, _ in UUID() })

    /// The environment's default: fails loudly if a screen forgets the live client, instead of saving nothing.
    static let unconfigured = ItemClient(update: { _, _ in
        assertionFailure("Set \\.itemClient at the app root")
        throw LibraryClientError.notAllowed
    })
}

private struct UpdatedItem: Decodable, Sendable {
    let id: UUID
}

private struct EnsureItemParams: Encodable, Sendable {
    let targetHousehold: UUID
    let itemName: String
    let itemCategory: ItemCategory

    enum CodingKeys: String, CodingKey {
        case targetHousehold = "target_household"
        case itemName = "item_name"
        case itemCategory = "item_category"
    }
}
