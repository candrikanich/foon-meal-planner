import SwiftUI
import TipKit

struct RootTabView: View {
    @Environment(HouseholdStore.self) private var household
    @State private var selection: AppTab = .week
    @State private var library: LibraryStore
    @State private var week: WeekStore
    @State private var dinner: DinnerStore
    @State private var ideas: IdeasStore
    @State private var freezer: FreezerStore
    @State private var activity: PlanActivityStore
    @State private var reminders: ReminderStore
    @State private var polls: PollStore
    @State private var calendarBusy: CalendarBusyStore
    private let router = ReminderRouter.shared
    private let householdID: UUID
    @Environment(\.aiJobClient) private var aiJobClient
    @Environment(\.scenePhase) private var scenePhase
    /// What the Share Sheet extension saved, the one being handled, and any put off with Not now until the next launch.
    @State private var waitingShares: [SharedItem] = []
    @State private var shared: SharedItem?
    @State private var postponedShares: Set<UUID> = []

    init(householdID: UUID, libraryClient: LibraryClient, weekClient: WeekClient, dinnerClient: DinnerClient,
         ideasClient: IdeasClient, freezerClient: FreezerClient, notificationClient: NotificationClient = .preview,
         pollClient: PollClient = .preview, calendarSource: CalendarSource = .system) {
        self.householdID = householdID
        _library = State(initialValue: LibraryStore(householdID: householdID, client: libraryClient))
        _week = State(initialValue: WeekStore(householdID: householdID, client: weekClient))
        _dinner = State(initialValue: DinnerStore(householdID: householdID, client: dinnerClient, waiting: ReminderDevice()))
        _ideas = State(initialValue: IdeasStore(householdID: householdID, client: ideasClient))
        _freezer = State(initialValue: FreezerStore(householdID: householdID, client: freezerClient))
        _activity = State(initialValue: PlanActivityStore(householdID: householdID, client: weekClient))
        _reminders = State(initialValue: ReminderStore(householdID: householdID, client: notificationClient))
        _polls = State(initialValue: PollStore(client: pollClient))
        _calendarBusy = State(initialValue: CalendarBusyStore(source: calendarSource))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    screen(for: tab)
                        .safeAreaInset(edge: .top, spacing: 0) { sharedBanner }
                }
            }
        }
        .environment(library)
        .environment(week)
        .environment(dinner)
        .environment(ideas)
        .environment(freezer)
        .environment(activity)
        .environment(reminders)
        .environment(polls)
        .environment(calendarBusy)
        .environment(router)
        .environment(\.showTab) { selection = $0 }
        .modifier(ReminderRunner(store: reminders, week: week.week, logs: dinner.logs))
        .modifier(PivotRunner(week: week, library: library, dinner: dinner))
        .modifier(TonightWidgetRunner(week: week.week))
        .modifier(AIQueueRunner(householdID: householdID, client: aiJobClient))
        // This Week opens the night or the card once it's on screen, and takes the route. Lists and Ideas need nothing more.
        .onChange(of: router.route, initial: true) { _, route in
            guard let route else { return }
            selection = route.tab
            if route.tab != .week { router.clear() }
            // Ideas may already be the tab, so its own load won't run again to show what the push was about.
            if route == .ideas { Task { await ideas.load() } }
        }
        .sheet(item: $shared) { item in
            SharedItemSheet(item: item) { outcome in finishShared(item, outcome) }
                .environment(household)
                .environment(library)
                .environment(ideas)
        }
        .task { refreshShared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshShared() }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: onboarding) { onboardingFlow }
        #else
        .sheet(isPresented: onboarding) { onboardingFlow.frame(minWidth: 520, minHeight: 640) }
        #endif
    }

    /// A banner rather than a sheet of its own: the app may be open on store mode, cook mode, or any other sheet, and a
    /// share shouldn't interrupt them (or fail to appear over them).
    @ViewBuilder
    private var sharedBanner: some View {
        if let next = waitingShares.first, !household.needsOnboarding {
            Button { shared = next } label: {
                Label(waitingShares.count == 1 ? String(localized: "You shared something with Foon")
                                               : String(localized: "You shared \(waitingShares.count) things with Foon"),
                      systemImage: "square.and.arrow.down")
                    .font(.foonBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Palette.cardSurface)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens it")
        }
    }

    private func refreshShared() {
        let pending = SharedInbox.shared?.pending() ?? []
        // They've found the share sheet, so the tip on Ideas has done its job.
        if !pending.isEmpty { ShareToFoonTip().invalidate(reason: .actionPerformed) }
        waitingShares = pending.filter { !postponedShares.contains($0.id) }
    }

    private func finishShared(_ item: SharedItem, _ outcome: SharedItemSheet.Outcome) {
        switch outcome {
        case .postponed: postponedShares.insert(item.id)
        case .done(let tab):
            SharedInbox.shared?.remove(item)
            if let tab { selection = tab }
        }
        shared = nil
        refreshShared()
    }

    /// The owner's first-run setup, over the app until it's done; it ends on This Week.
    private var onboarding: Binding<Bool> {
        Binding(get: { household.needsOnboarding }, set: { _ in })
    }

    private var onboardingFlow: some View {
        OnboardingFlow { selection = .week }
            .environment(household)
            .environment(library)
            .environment(week)
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .week: WeekView()
        case .library: LibraryView()
        case .lists: ListsView()
        case .ideas: IdeasView()
        case .family: FamilyView()
        }
    }
}

#Preview {
    let store = HouseholdStore.preview()
    RootTabView(householdID: Household.sample.id, libraryClient: .preview(), weekClient: .preview(started: true),
                dinnerClient: .preview, ideasClient: .preview(), freezerClient: .preview)
        .environment(SessionStore(auth: .preview()))
        .environment(store)
        .environment(\.storeRunClient, .preview)
        .task { await store.load() }
}
