import Foundation
import Observation
import Supabase

/// The freezer stash (docs/spec.md → Cook once, eat twice): dinners cooked ahead, with dates. Anyone in the family adds to
/// it and uses it up; planning a night from it goes through Swap. Needs a connection: unlike the lists, what's in it
/// changes who can have what, so a stale copy isn't worth offering.
@Observable @MainActor
final class FreezerStore {
    private(set) var items: [FreezerItem] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let householdID: UUID
    private let client: FreezerClient

    init(householdID: UUID, client: FreezerClient) {
        self.householdID = householdID
        self.client = client
    }

    /// Oldest first, so what's been in there longest is what's seen first.
    var inTheFreezer: [FreezerItem] {
        items.filter { $0.state == .in }.sorted { ($0.madeOn, $0.id.uuidString) < ($1.madeOn, $1.id.uuidString) }
    }

    var planned: [FreezerItem] {
        items.filter { $0.state == .used && $0.plannedOn != nil }
    }

    /// Used up or tossed: kept so a mistaken tap can be put back.
    var gone: [FreezerItem] {
        items.filter { $0.state != .in && $0.plannedOn == nil }.sorted { $0.madeOn > $1.madeOn }
    }

    func load() async {
        do {
            items = try await client.items(householdID)
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            errorMessage = String(localized: "Couldn't load the freezer. Check your connection and try again.")
        }
    }

    @discardableResult
    func add(mealID: UUID, madeOn: CalendarDay) async -> Bool {
        do {
            try await client.add(householdID, mealID, madeOn)
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = message(for: error, otherwise: String(localized: "Couldn't add that to the freezer. Check your connection and try again."))
            return false
        }
    }

    func setState(_ state: FreezerItem.State, item: FreezerItem) async {
        do {
            try await client.setState(item.id, state)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error, otherwise: String(localized: "Couldn't change that. Check your connection and try again."))
        }
        let refused = errorMessage
        await load()
        if let refused { errorMessage = refused }
    }

    private func message(for error: any Error, otherwise: String) -> String {
        switch (error as? PostgrestError)?.code {
        case "FD002": String(localized: "Someone already changed that one. Here's what's in the freezer now.")
        case "22023": String(localized: "Pick today or an earlier day: it has to be made already.")
        case "42501": String(localized: "Only people in this family can change its freezer.")
        default: otherwise
        }
    }
}
