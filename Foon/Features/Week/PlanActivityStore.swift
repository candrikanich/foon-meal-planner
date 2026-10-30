import Foundation
import Observation

/// The household's recent plan changes, for a night's detail and the activity view. Undo itself goes through `WeekStore`, which
/// owns the night's writes.
@Observable @MainActor
final class PlanActivityStore {
    private(set) var changes: [PlanChange] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let householdID: UUID
    private let client: WeekClient
    private var loadGeneration = 0

    init(householdID: UUID, client: WeekClient) {
        self.householdID = householdID
        self.client = client
    }

    var entries: [PlanActivity.Entry] { PlanActivity.entries(changes) }

    func changes(on nightID: UUID) -> [PlanChange] {
        PlanActivity.changes(on: nightID, in: changes)
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let loaded = try await client.planChanges(householdID)
            guard generation == loadGeneration else { return }
            changes = loaded
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            errorMessage = String(localized: "Couldn't load the activity. Check your connection and try again.")
        }
    }
}
