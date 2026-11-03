import Foundation
import Supabase
import SwiftData

/// Who's asking Siri, from what this phone already has: the signed-in account and the household its cache holds. No
/// network.
@MainActor
struct IntentHousehold {
    let id: UUID
    let userID: UUID
    let client: SupabaseClient
    let context: ModelContext

    /// The signed-in account's client, or nil when no one is signed in.
    static var signedInClient: SupabaseClient? {
        guard FoonApp.configured else { return nil }
        let client = SupabaseService.shared.client
        return client.auth.currentUser == nil ? nil : client
    }

    /// Nil when signed out, or before this phone has synced the household (a new one, or just switched).
    static func current() -> IntentHousehold? {
        guard let client = signedInClient, let user = client.auth.currentUser else { return nil }
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

    /// Why there's no household: no one signed in, or this phone hasn't synced it yet.
    static var unavailable: String {
        signedInClient == nil
            ? String(localized: "Open Foon and sign in first.", comment: "Siri, with no one signed in")
            : String(localized: "Open Foon first, so this phone has your family's lists.",
                     comment: "Siri, signed in but nothing synced yet")
    }
}
