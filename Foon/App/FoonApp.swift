import SwiftData
import SwiftUI
import UserNotifications

@main
struct FoonApp: App {
    @State private var session: SessionStore? = Self.configured
        ? SessionStore(auth: .live(SupabaseService.shared.client)) : nil

    private static let configured = (try? SupabaseConfig.fromMainBundle()) != nil
    // The offline cache. If the store can't open, the app still runs with an in-memory cache.
    private static let cache = (try? SyncService.persistentContainer()) ?? (try! SyncService.inMemoryContainer())

    init() {
        // Cook-mode timer alerts show (with sound) even while Foon is in front.
        UNUserNotificationCenter.current().delegate = CookAlertPresenter.shared
    }

    // One window (Mac) or scene (iPad): each would run its own sync service against the same cache.
    var body: some Scene {
        #if os(macOS)
        Window("Foon", id: "main") { root }
        #else
        WindowGroup { root }
        #endif
    }

    @ViewBuilder
    private var root: some View {
        if let session {
            RootView(householdClient: .live(SupabaseService.shared.client),
                     syncClient: .live(SupabaseService.shared.client),
                     libraryClient: .live(SupabaseService.shared.client),
                     weekClient: .live(SupabaseService.shared.client),
                     dinnerClient: .live(SupabaseService.shared.client),
                     ideasClient: .live(SupabaseService.shared.client),
                     freezerClient: .live(SupabaseService.shared.client))
                .environment(session)
                .environment(\.itemClient, .live(SupabaseService.shared.client))
                .modelContainer(Self.cache)
                .task { await session.start() }
                .onOpenURL { session.open($0) }
        } else {
            ConfigurationMissingView()
        }
    }
}
