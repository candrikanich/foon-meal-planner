import SwiftUI

struct RootTabView: View {
    @State private var selection: AppTab = .week
    @State private var library: LibraryStore

    init(householdID: UUID, libraryClient: LibraryClient) {
        _library = State(initialValue: LibraryStore(householdID: householdID, client: libraryClient))
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
    RootTabView(householdID: Household.sample.id, libraryClient: .preview())
        .environment(SessionStore(auth: .preview()))
        .environment(store)
        .task { await store.load() }
}
