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
    let freezerClient: FreezerClient
    var notificationClient: NotificationClient = .preview
    var pollClient: PollClient = .preview
    var subscriptionClient: SubscriptionClient = .preview()
    var storeKit: StoreKitClient = .preview

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .restoring:
            ProgressView()
        case .signedOut:
            WelcomeView()
        case .signedIn(let userID):
            HouseholdGate(userID: userID, client: householdClient, syncClient: syncClient, libraryClient: libraryClient,
                          weekClient: weekClient, dinnerClient: dinnerClient, ideasClient: ideasClient,
                          freezerClient: freezerClient, notificationClient: notificationClient, pollClient: pollClient,
                          subscriptionClient: subscriptionClient, storeKit: storeKit)
                .id(userID)
        }
    }

    var body: some View {
        content
            .onChange(of: session.state) { previous, state in
                switch state {
                case .signedOut:
                    // The next person to sign in on this device must never see this household's week or lists.
                    SyncServices.shared.stopCurrent()
                    try? SyncService.clearCache(in: context)
                    // And no reminder of theirs goes off for them.
                    ReminderStore.clearDevice()
                    EditingAllowed.clear()
                    // Nor does their calendar choice carry over.
                    CalendarBusyStore.clearDevice()
                    DinnerMemoriesStore.clearDevice()
                    // Nor does the Tonight widget keep showing their dinners.
                    TonightFile.shared?.clear()
                    // Signing out drops what's waiting. Launching signed out doesn't: someone may have just shared
                    // something and be on their way to sign in.
                    if case .signedIn = previous { SharedInbox.shared?.clear() }
                case .signedIn(let userID):
                    SharedInbox.shared?.claim(for: userID)
                case .restoring:
                    break
                }
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
    let freezerClient: FreezerClient
    let notificationClient: NotificationClient
    let pollClient: PollClient
    let subscriptionClient: SubscriptionClient
    let storeKit: StoreKitClient

    init(userID: UUID, client: HouseholdClient, syncClient: SyncClient, libraryClient: LibraryClient,
         weekClient: WeekClient, dinnerClient: DinnerClient, ideasClient: IdeasClient, freezerClient: FreezerClient,
         notificationClient: NotificationClient, pollClient: PollClient,
         subscriptionClient: SubscriptionClient = .preview(), storeKit: StoreKitClient = .preview) {
        _store = State(initialValue: HouseholdStore(userID: userID, client: client))
        self.syncClient = syncClient
        self.libraryClient = libraryClient
        self.weekClient = weekClient
        self.dinnerClient = dinnerClient
        self.ideasClient = ideasClient
        self.freezerClient = freezerClient
        self.notificationClient = notificationClient
        self.pollClient = pollClient
        self.subscriptionClient = subscriptionClient
        self.storeKit = storeKit
    }

    var body: some View {
        // A ZStack keeps one identity across phases, so the load runs once rather than per screen.
        ZStack {
            switch store.phase {
            case .loading:
                ProgressView()
            case .needsHousehold:
                CreateHouseholdView()
                    .task { clearHouseholdFromDevice() }
            case .held(let hold):
                // Signed out of the household like a withdrawal, so nothing of it stays here meanwhile.
                HeldAccessView(hold: hold)
                    .task { clearHouseholdFromDevice() }
            case .ready(let household):
                if let gate = store.termsGate() {
                    AgreementsGateView(gate: gate)
                } else {
                    SyncGate(householdID: household.id, client: syncClient) {
                        RootTabView(householdID: household.id, libraryClient: libraryClient, weekClient: weekClient,
                                    dinnerClient: dinnerClient, ideasClient: ideasClient, freezerClient: freezerClient,
                                    notificationClient: notificationClient, pollClient: pollClient,
                                    subscriptionClient: subscriptionClient, storeKit: storeKit)
                    }
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
        // A significant change (#88) waits for a parent's OK or an adult's acknowledgment where the law asks for one.
        .modifier(SignificantChangeGate())
    }

    /// No household for this account (the owner deleted it, this person was removed, or a hold signed them out):
    /// nothing of the old one may stay on the device. Their sync service stops first, so no late pull can refill the
    /// cache.
    private func clearHouseholdFromDevice() {
        SyncServices.shared.stopCurrent()
        try? SyncService.clearCache(in: context)
        ReminderStore.clearDevice()
        CalendarBusyStore.clearDevice()
        DinnerMemoriesStore.clearDevice()
        TonightFile.shared?.clear()
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
    RootView(householdClient: .preview(), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Signed in, new") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    RootView(householdClient: .preview(household: nil), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Signed in") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    RootView(householdClient: .preview(), syncClient: .preview, libraryClient: .preview(), weekClient: .preview(), dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("Not configured") {
    ConfigurationMissingView()
}

#Preview("Signed in, Terms to agree to") {
    let session = SessionStore(auth: .preview(signedIn: .previewUser))
    var client = HouseholdClient.preview()
    client.agreements = { _ in .previewTermsNew }
    return RootView(householdClient: client, syncClient: .preview, libraryClient: .preview(), weekClient: .preview(),
                    dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}

#Preview("A kid signed out until a parent agrees") {
    let session = SessionStore(auth: .preview(signedIn: UUID()))
    var client = HouseholdClient.preview(household: nil)
    client.accessHold = { .preview }
    return RootView(householdClient: client, syncClient: .preview, libraryClient: .preview(), weekClient: .preview(),
                    dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(session)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await session.start() }
}
