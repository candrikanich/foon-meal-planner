import SwiftData
import SwiftUI
import UserNotifications

@main
struct FoonApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(FoonAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(FoonAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionStore? = Self.configured
        ? SessionStore(auth: .live(SupabaseService.shared.client)) : nil

    // Nonisolated: the background refresh reads it off the main actor.
    nonisolated static let configured = (try? SupabaseConfig.fromMainBundle()) != nil
    // The offline cache, which Siri's intents use too. If the store can't open, the app still runs with an in-memory one.
    static let cache = (try? SyncService.persistentContainer()) ?? (try! SyncService.inMemoryContainer())

    init() {
        // Cook-mode timer alerts show (with sound) even while Foon is in front.
        UNUserNotificationCenter.current().delegate = CookAlertPresenter.shared
        ReminderCenter.registerActions()
        FoonTips.configure()
    }

    // One window (Mac) or scene (iPad): each would run its own sync service against the same cache.
    var body: some Scene {
        #if os(macOS)
        Window("Foon", id: "main") { root }
        #else
        WindowGroup { root }
            // The after-dinner card's answers wait for the app; this gives iOS a chance to send them without it opening.
            // A capable device also asks for a refresh to take the family's waiting AI jobs.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background, Self.configured else { return }
                Task { await AnswerRefresh.scheduleNext(device: ReminderDevice()) }
                AIRefresh.scheduleIfCapable()
            }
            .backgroundTask(.appRefresh(AnswerRefresh.id)) {
                guard Self.configured else { return }
                let device = ReminderDevice()
                await WaitingAnswers.send(device: device, client: .live(SupabaseService.shared.client))
                // Each refresh asks for the next: for answers still waiting, or the next prompt's card.
                await AnswerRefresh.scheduleNext(device: device)
            }
            // A capable iPhone or iPad takes one of the family's waiting AI jobs.
            .backgroundTask(.appRefresh(AIRefresh.id)) {
                guard Self.configured else { return }
                await AIRefresh.run(client: .live(SupabaseService.shared.client))
            }
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
                     freezerClient: .live(SupabaseService.shared.client),
                     notificationClient: .live(SupabaseService.shared.client),
                     pollClient: .live(SupabaseService.shared.client))
                .environment(session)
                .environment(\.itemClient, .live(SupabaseService.shared.client))
                .environment(\.storeRunClient, .live(SupabaseService.shared.client))
                .environment(\.receiptClient, .live(SupabaseService.shared.client))
                .environment(\.aiJobClient, .live(SupabaseService.shared.client))
                .modelContainer(Self.cache)
                .task { await session.start() }
                .onOpenURL { session.open($0) }
        } else {
            ConfigurationMissingView()
        }
    }
}
