import Foundation

/// Puts named items on the quick list, from the list screen, the share sheet, or Siri.
enum QuickListAdder {
    struct Result: Equatable {
        var added: [String] = []
        var failed: [String] = []
        /// Some of `failed` were new items, which need a connection to be created.
        var newItemsOffline = false

        /// For the list screen and the share sheet: nil when everything went on.
        var message: String? {
            guard !failed.isEmpty else { return nil }
            let list = failed.formatted(.list(type: .and))
            return newItemsOffline
                ? String(localized: "Couldn't add \(list). New items need a connection; try again.")
                : String(localized: "Couldn't add \(list). Try again.")
        }

        /// What Siri says. An add made offline is true already (it's on this phone's list and queued), so it says so and
        /// that the family sees it once there's signal.
        func spoken(waitingForSignal: Bool) -> String {
            var parts: [String] = []
            if !added.isEmpty {
                let list = added.formatted(.list(type: .and))
                parts.append(waitingForSignal
                    ? String(localized: "Added \(list). It'll reach the family when you're back online.",
                             comment: "Siri, after adding to the quick list offline")
                    : String(localized: "Added \(list).", comment: "Siri, after adding to the quick list"))
            }
            if let message { parts.append(message) }
            return parts.joined(separator: " ")
        }
    }

    @MainActor
    static func add(_ names: [String], urgency: ListUrgency = .whenever, items: [CachedItem], householdID: UUID,
                    itemClient: ItemClient, sync: SyncService) async -> Result {
        let known = Dictionary(items.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        var result = Result()
        var created = false
        for name in names {
            var itemID = known[name.lowercased()]
            if itemID == nil {
                do {
                    itemID = try await itemClient.ensure(householdID, name, ItemCategory.guess(for: name) ?? .other)
                    created = true
                } catch {
                    if OfflineReplay.classify(error) == .offline { result.newItemsOffline = true }
                }
            }
            guard let itemID else {
                result.failed.append(name)
                continue
            }
            await sync.addToList(itemID: itemID, list: .quick, urgency: urgency)
            result.added.append(name)
        }
        // A new item's name and aisle come with the next pull; fetch it now rather than show "Item".
        if created { await sync.pull() }
        return result
    }
}
