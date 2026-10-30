import SwiftUI

struct RootTabView: View {
    @Environment(HouseholdStore.self) private var household
    @State private var selection: AppTab = .week
    @State private var library: LibraryStore
    @State private var week: WeekStore
    @State private var dinner: DinnerStore
    @State private var ideas: IdeasStore
    @Environment(\.scenePhase) private var scenePhase
    /// What the Share Sheet extension saved, the one being handled, and any put off with Not now until the next launch.
    @State private var waitingShares: [SharedItem] = []
    @State private var shared: SharedItem?
    @State private var postponedShares: Set<UUID> = []

    init(householdID: UUID, libraryClient: LibraryClient, weekClient: WeekClient, dinnerClient: DinnerClient,
         ideasClient: IdeasClient) {
        _library = State(initialValue: LibraryStore(householdID: householdID, client: libraryClient))
        _week = State(initialValue: WeekStore(householdID: householdID, client: weekClient))
        _dinner = State(initialValue: DinnerStore(householdID: householdID, client: dinnerClient))
        _ideas = State(initialValue: IdeasStore(householdID: householdID, client: ideasClient))
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
        .environment(\.showTab) { selection = $0 }
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
        waitingShares = (SharedInbox.shared?.pending() ?? []).filter { !postponedShares.contains($0.id) }
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
                dinnerClient: .preview, ideasClient: .preview())
        .environment(SessionStore(auth: .preview()))
        .environment(store)
        .task { await store.load() }
}
