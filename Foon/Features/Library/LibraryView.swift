import SwiftUI

/// The household's meals (docs/spec.md → Library screen): search, filter chips, sorts, and a photo grid.
/// Matching starter dishes appear below the family's own when searching.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(IdeasStore.self) private var ideas: IdeasStore?
    @State private var browsingCatalog = false
    @State private var quickAdding = false
    @State private var planning: LibraryMeal?
    @State private var bringingBack: LibraryMeal?
    @State private var deleting: LibraryMeal?
    @State private var importingLink = false
    @State private var path: [UUID] = []

    private var canEdit: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    /// The keyboard covers the tab bar while searching, so there has to be a way out that isn't the search field's own.
    @FocusState private var isSearching: Bool

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FilterChips(selection: $library.filter)
                    if let message = library.errorMessage {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                    content
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Palette.cream)
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                MealDetailView(mealID: id, canEdit: canEdit)
            }
            .searchable(text: $library.search, prompt: Text("Meals or ingredients"))
            .searchFocused($isSearching)
            .onSubmit(of: .search) { isSearching = false }
            .toolbar { toolbar }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isSearching = false }
                }
            }
            .refreshable { await library.load(members: household.members) }
            .confirmationDialog("Bring back a dish the family voted out?", isPresented: Binding(
                get: { bringingBack != nil }, set: { if !$0 { bringingBack = nil } }
            ), titleVisibility: .visible, presenting: bringingBack) { meal in
                Button("Back in rotation") { Task { await library.setArchived(false, mealID: meal.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It'll still stay off nights when anyone who said Not for me is home, and another Not for me retires it again.")
            }
            .confirmationDialog("Delete this dish?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { meal in
                Button("Delete", role: .destructive) {
                    Task { if await library.delete(meal) { await ideas?.dishDeleted(meal.id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { meal in
                Text("\(meal.name) has never been planned or cooked. This can't be undone.")
            }
            .sheet(item: $planning, onDismiss: { Task { await library.refreshUnused() } }) { meal in PlanItSheet(meal: meal) }
            .sheet(isPresented: $browsingCatalog) {
                CatalogBrowserView(canAdd: canEdit)
            }
            .sheet(isPresented: $quickAdding) {
                QuickAddView { id in path = [id] }
            }
            .sheet(isPresented: $importingLink) {
                LinkImportView { id in path = [id] }
            }
        }
        .task(id: household.members) { await library.load(members: household.members) }
    }

    @ViewBuilder
    private var content: some View {
        let entries = library.visibleEntries
        let catalogMatches = library.catalogMatches
        if !library.hasLoaded && library.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if entries.isEmpty && catalogMatches.isEmpty {
            emptyState
        } else {
            if let note = LibraryText.uncheckedFilterNote(filter: library.filter, unchecked: library.uncheckedCount) {
                Label(note, systemImage: "questionmark.circle")
                    .font(.foonCaption)
                    .foregroundStyle(Palette.caution)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.meal.id) {
                        MealTile(entry: entry, madeBy: library.member(entry.meal.madeByMemberID),
                                 photoURL: library.photoURL(for:))
                    }
                    .buttonStyle(.plain)
                    .contextMenu(menuItems: { menu(for: entry.meal) })
                }
            }
            if !catalogMatches.isEmpty {
                CatalogMatches(dishes: catalogMatches, canAdd: canEdit)
            }
        }
    }

    /// Empty for members, which shows no menu at all. Retired dishes offer Back in rotation, after a confirmation. Delete only
    /// for a dish that's never been used.
    @ViewBuilder
    private func menu(for meal: LibraryMeal) -> some View {
        if canEdit && meal.status.isInRotation {
            Button("Plan it", systemImage: "calendar.badge.plus") { planning = meal }
            Button("Archive", systemImage: "archivebox") {
                Task { await library.setArchived(true, mealID: meal.id) }
            }
        } else if canEdit && LibraryStore.canRestore(meal) {
            Button("Back in rotation", systemImage: "arrow.uturn.backward") { restore(meal) }
        }
        if canEdit && library.canDelete(meal) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = meal }
        }
    }

    /// Back in rotation: right away for an archived dish; a retired one asks first, since the family voted it out.
    private func restore(_ meal: LibraryMeal) {
        if meal.status == .retired {
            bringingBack = meal
        } else {
            Task { await library.setArchived(false, mealID: meal.id) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if canEdit {
                    Button("Quick add", systemImage: "square.and.pencil") { quickAdding = true }
                    Button("From a link", systemImage: "link") { importingLink = true }
                }
                Button("Browse ideas", systemImage: "sparkles") { browsingCatalog = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            @Bindable var library = library
            Picker("Sort", selection: $library.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let copy = LibraryText.emptyState(filter: library.filter, searching: !library.search.isEmpty,
                                          unchecked: library.uncheckedCount)
        ContentUnavailableView {
            Label(copy.title, systemImage: copy.systemImage)
        } description: {
            Text(copy.message)
        } actions: {
            if library.filter == nil && library.search.isEmpty {
                if canEdit {
                    Button("Quick add") { quickAdding = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.paprika)
                }
                Button("Browse ideas") { browsingCatalog = true }
                    .buttonStyle(.bordered)
                    .tint(Palette.paprika)
            }
        }
        .frame(minHeight: 320)
    }
}

/// One chip per filter; tapping the chosen one again clears it.
private struct FilterChips: View {
    @Binding var selection: LibraryFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { filter in
                    let isOn = selection == filter
                    Button {
                        selection = isOn ? nil : filter
                    } label: {
                        Text(filter.title)
                            .font(.foonCaption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(isOn ? Palette.onPaprika : Palette.ink)
                            .background(Capsule().fill(isOn ? Palette.paprika : Palette.cardSurface))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
    }
}

/// Starter dishes that match a search, below the family's own.
private struct CatalogMatches: View {
    @Environment(LibraryStore.self) private var library
    let dishes: [CatalogDish]
    let canAdd: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From Foon's ideas").font(.foonHeadline).foregroundStyle(.secondary)
            ForEach(dishes) { dish in
                CatalogDishRow(dish: dish, canAdd: canAdd)
                Divider()
            }
        }
        .padding(.top, 8)
    }
}

extension LibraryText {
    struct EmptyState: Equatable {
        let title: String
        let message: String
        let systemImage: String
    }

    /// The Allergy flags filter lists what's flagged; this says what it can't vouch for, so the list doesn't read as
    /// complete. Counts a dish with no ingredients, one whose side has none, and one whose side can't be found.
    static func uncheckedFilterNote(filter: LibraryFilter?, unchecked: Int) -> String? {
        filter == .allergyFlags && unchecked > 0 ? uncheckedNote(unchecked) : nil
    }

    private static func uncheckedNote(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 meal can't be fully checked for allergies. Open it to see why.")
            : String(localized: "\(count) meals can't be fully checked for allergies. Open them to see why.")
    }

    static func emptyState(filter: LibraryFilter?, searching: Bool, unchecked: Int = 0) -> EmptyState {
        if searching {
            return EmptyState(title: String(localized: "No matches"),
                              message: String(localized: "Try another meal or ingredient."),
                              systemImage: "magnifyingglass")
        }
        switch filter {
        case nil:
            return EmptyState(title: String(localized: "No meals yet"),
                              message: String(localized: "Add the dinners your family already makes."),
                              systemImage: "book")
        case .favorites:
            return EmptyState(title: String(localized: "No favorites yet"),
                              message: String(localized: "Favorites come from how the family rates dinners."),
                              systemImage: "heart")
        case .quick:
            return EmptyState(title: String(localized: "No quick meals"),
                              message: String(localized: "Meals tagged quick take under 30 minutes."),
                              systemImage: "hare")
        case .trying:
            return EmptyState(title: String(localized: "Nothing on trial"),
                              message: String(localized: "New dishes you're trying out show up here."),
                              systemImage: "sparkles")
        case .backup:
            return EmptyState(title: String(localized: "No backup dinners"),
                              message: String(localized: "Backup dinners are the ones you can make from the freezer or pantry."),
                              systemImage: "shippingbox")
        case .allergyFlags where unchecked > 0:
            // Nothing flagged isn't the same as nothing to worry about.
            return EmptyState(title: String(localized: "No allergy flags"),
                              message: uncheckedNote(unchecked),
                              systemImage: "questionmark.circle")
        case .allergyFlags:
            return EmptyState(title: String(localized: "No allergy flags"),
                              message: String(localized: "None of your meals contain anything your family avoids."),
                              systemImage: "checkmark.shield")
        case .archived:
            return EmptyState(title: String(localized: "Nothing archived"),
                              message: String(localized: "Archived meals leave the rotation but keep their history."),
                              systemImage: "archivebox")
        }
    }
}

#Preview("Library") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    LibraryView()
        .environment(household)
        .environment(library)
        .task { await household.load() }
}

#Preview("Empty") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview(meals: []))
    LibraryView()
        .environment(household)
        .environment(library)
        .task { await household.load() }
}
