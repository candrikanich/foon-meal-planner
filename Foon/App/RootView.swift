import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch session.state {
        case .restoring:
            ProgressView()
        case .signedOut:
            WelcomeView()
        case .signedIn:
            RootTabView()
        }
    }
}

/// Debug builds run without Supabase settings (CI, fresh clones); Staging and Release refuse to build without them.
struct ConfigurationMissingView: View {
    var body: some View {
        ContentUnavailableView(
            "Supabase isn't configured",
            systemImage: "wrench.and.screwdriver",
            description: Text("Run scripts/write-local-config.sh after supabase start. See README → Local Supabase.")
        )
    }
}

#Preview("Signed out") {
    let session = SessionStore(auth: .preview())
    RootView()
        .environment(session)
        .task { await session.start() }
}

#Preview("Signed in") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    RootView()
        .environment(session)
        .task { await session.start() }
}

#Preview("Not configured") {
    ConfigurationMissingView()
}
