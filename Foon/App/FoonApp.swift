import SwiftUI

@main
struct FoonApp: App {
    @State private var session: SessionStore? = Self.configured
        ? SessionStore(auth: .live(SupabaseService.shared.client)) : nil

    private static let configured = (try? SupabaseConfig.fromMainBundle()) != nil

    var body: some Scene {
        WindowGroup {
            if let session {
                RootView(householdClient: .live(SupabaseService.shared.client))
                    .environment(session)
                    .task { await session.start() }
            } else {
                ConfigurationMissingView()
            }
        }
    }
}
