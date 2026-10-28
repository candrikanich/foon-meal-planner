import SwiftUI

struct RootTabView: View {
    @Environment(HouseholdStore.self) private var household
    @State private var selection: AppTab = .week
    @State private var library: LibraryStore
    @State private var week: WeekStore

    init(householdID: UUID, libraryClient: LibraryClient, weekClient: WeekClient) {
        _library = State(initialValue: LibraryStore(householdID: householdID, client: libraryClient))
        _week = State(initialValue: WeekStore(householdID: householdID, client: weekClient))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    screen(for: tab)
                }
            }
        }
        .environment(library)
        .environment(week)
        .environment(\.showTab) { selection = $0 }
        #if os(iOS)
        .fullScreenCover(isPresented: onboarding) { onboardingFlow }
        #else
        .sheet(isPresented: onboarding) { onboardingFlow.frame(minWidth: 520, minHeight: 640) }
        #endif
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
    RootTabView(householdID: Household.sample.id, libraryClient: .preview(), weekClient: .preview(started: true))
        .environment(SessionStore(auth: .preview()))
        .environment(store)
        .task { await store.load() }
}
