import SwiftUI

@main
struct FoonApp: App {
    @State private var session: SessionStore? = (try? SupabaseConfig.fromMainBundle()).map { _ in
        SessionStore(auth: .live(SupabaseService.shared.client))
    }

    var body: some Scene {
        WindowGroup {
            if let session {
                RootView()
                    .environment(session)
                    .task { await session.start() }
            } else {
                ConfigurationMissingView()
            }
        }
    }
}
