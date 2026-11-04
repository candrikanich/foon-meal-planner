import Foundation
import Supabase

/// What a receipt scan reads from the server. Both need a connection, and a scan works without them: offline the matcher
/// runs on its own and no staples are suggested. Teaching an alias goes through the sync queue instead
/// (`OfflineChange.teachReceiptAlias`), so a correction made offline isn't lost.
struct ReceiptClient: Sendable {
    /// What the household has taught (`receipt_aliases`).
    var aliases: @Sendable (_ householdID: UUID) async throws -> [ReceiptAlias]
    /// Which of these items were checked off a list in the window.
    var checkedOff: @Sendable (_ householdID: UUID, _ items: [UUID], _ window: ClosedRange<Date>) async throws -> Set<UUID>
}

extension ReceiptClient {
    static func live(_ client: SupabaseClient) -> ReceiptClient {
        ReceiptClient(
            aliases: { householdID in
                try await client.from("receipt_aliases")
                    .select("raw_text, item_id")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            checkedOff: { householdID, items, window in
                guard !items.isEmpty else { return [] }
                let format = ISO8601DateFormatter()
                let rows: [CheckedOffItem] = try await client.from("list_items")
                    .select("item_id")
                    .eq("household_id", value: householdID)
                    .in("item_id", values: items)
                    .gte("checked_at", value: format.string(from: window.lowerBound))
                    .lte("checked_at", value: format.string(from: window.upperBound))
                    .execute()
                    .value
                return Set(rows.map(\.itemID))
            }
        )
    }

    static func preview(aliases: [ReceiptAlias] = [], checkedOff: Set<UUID> = []) -> ReceiptClient {
        ReceiptClient(aliases: { _ in aliases }, checkedOff: { _, items, _ in checkedOff.intersection(items) })
    }

    /// The environment's default: fails loudly if a screen forgets the live client.
    static let unconfigured = ReceiptClient(aliases: { _ in
        assertionFailure("Set \\.receiptClient at the app root")
        return []
    }, checkedOff: { _, _, _ in [] })
}

private struct CheckedOffItem: Decodable, Sendable {
    let itemID: UUID
    enum CodingKeys: String, CodingKey { case itemID = "item_id" }
}
