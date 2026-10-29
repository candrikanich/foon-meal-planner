import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.modelContext) private var context
    let householdClient: HouseholdClient
    let syncClient: SyncClient
    let libraryClient: LibraryClient
    let weekClient: WeekClient
    let dinnerClient: DinnerClient
    let ideasClient: IdeasClient

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .restoring:
            ProgressView()
        case .signedOut:
            WelcomeView()
        case .signedIn(let userID):
            HouseholdGate(userID: userID, client: householdClient, syncClient: syncClient, libraryClient: libraryClient,
                          weekClient: weekClient, dinnerClient: dinnerClient, ideasClient: ideasClient)
                .id(userID)
        }
    }

    var body: some View {
        content
            .onChange(of: session.state) { _, state in
                // The next person to sign in on this device must never see this household's week or lists.
                if state == .signedOut { try? SyncService.clearCache(in: context) }
            }
    }
}

/// Loads the signed-in person's household: create one first, otherwise the app.
struct HouseholdGate: View {
    @Environment(\.modelContext) private var context
    @State private var store: HouseholdStore
    let syncClient: SyncClient
    let libraryClient: LibraryClient
    let weekClient: WeekClient
    let dinnerClient: DinnerClient
    let ideasClient: IdeasClient

    init(userID: UUID, client: HouseholdClient, syncClient: SyncClient, libraryClient: LibraryClient,
         weekClient: WeekClient, dinnerClient: DinnerClient, ideasClient: IdeasClient) {
        _store = State(initialValue: HouseholdStore(userID: userID, client: client))
        self.syncClient = syncClient
        self.libraryClient = libraryClient
        self.weekClient = weekClient
        self.dinnerClient = dinnerClient
        self.ideasClient = ideasClient
    }

    var body: some View {
        // A ZStack keeps one identity across phases, so the load runs once rather than per screen.
        ZStack {
            switch store.phase {
            case .loading:
                ProgressView()
            case .needsHousehold:
                CreateHouseholdView()
                    .task {
                        // No household for this account (the owner deleted it, or this person was removed): nothing
                        // of the old one may stay on the device. This runs once the old screens are gone, after
                        // SyncGate stopped their service, so no late pull can refill the cache.
                        try? SyncService.clearCache(in: context)
                    }
            case .ready(let household):
                SyncGate(householdID: household.id, client: syncClient) {
                    RootTabView(householdID: household.id, libraryClient: libraryClient, weekClient: weekClient,
                                dinnerClient: dinnerClient, ideasClient: ideasClient)
                }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't load your household", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(store.errorMessage ?? "")
                } actions: {
                    Button("Try again") { Task { await store.load() } }
                        .disabled(store.isLoading)
                }
            }
        }
        .environment(store)
        .task { await store.load() }
    }
}

/// Debug builds run without Supabase settings (CI, fresh clones); Staging and Release refuse to build without them.
struct ConfigurationMissingView: View {
    var body: some View {
        // Developer-only, so it stays out of the String Catalog.
        ContentUnavailableView {
            Label { Text(verbatim: "Supabase isn't configured") } icon: { Image(systemName: "wrench.and.screwdriver") }
        } description: {
            Text(verbatim: "Run scripts/write-local-config.sh after supabase start. See README → Local Supabase.")
        }
    }
}

#Preview("Signed out") {
    let session = SessionStore(auth: .preview())
    RootView(householdClient: .preview(), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview())
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Signed in, new") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    RootView(householdClient: .preview(household: nil), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview())
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Signed in") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    RootView(householdClient: .preview(), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview())
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Not configured") {
    ConfigurationMissingView()
}
