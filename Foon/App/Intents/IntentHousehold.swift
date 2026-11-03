import Foundation
import Supabase
import SwiftData

/// Who's asking Siri, from what this phone already has: the signed-in account and the household its cache holds. No
/// network, and nothing when signed out (sign-out wipes the cache).
@MainActor
struct IntentHousehold {
    let id: UUID
    let userID: UUID
    let client: SupabaseClient
    let context: ModelContext

    static func current() -> IntentHousehold? {
        guard FoonApp.configured else { return nil }
        let client = SupabaseService.shared.client
        guard let user = client.auth.currentUser else { return nil }
        let context = FoonApp.cache.mainContext
        // The sync service keeps only one household's rows, so any row says which.
        let householdID = (try? context.fetch(FetchDescriptor<CachedPlan>()))?.first?.householdID
            ?? (try? context.fetch(FetchDescriptor<CachedItem>()))?.first?.householdID
        guard let householdID else { return nil }
        return IntentHousehold(id: householdID, userID: user.id, client: client, context: context)
    }

    /// The same service the open app runs, so a change goes out once.
    var sync: SyncService {
        SyncServices.shared.service(for: id, context: context, client: .live(client))
    }

    static let signedOut = String(localized: "Open Foon and sign in first.", comment: "Siri, with no one signed in")
}
