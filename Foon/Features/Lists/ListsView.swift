import SwiftData
import SwiftUI

/// The household's lists (docs/spec.md → Shopping and pantry), read from the offline cache so they work with no
/// signal: add an item, what's on the list (tonight first, then the week, then the rest), and staples running low.
/// Shop opens store mode. Everyone at home works the list.
struct ListsView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(HouseholdStore.self) private var household
    @Environment(\.itemClient) private var itemClient
    @Query private var lines: [CachedListItem]
    @Query private var items: [CachedItem]
    @State private var newItem = ""
    @State private var forTonight = false
    @State private var shopping = false
    @State private var openItem: ItemDetails?
    @State private var errorMessage: String?
    @Environment(\.storeRunClient) private var storeRunClient
    @State private var storeRuns: StoreRunStore?

    private var entries: [ListEntry] { ListEntry.entries(lines: lines, items: items) }

    private var staples: [ListBoard.Staple] {
        items.filter(\.keepOnHand).compactMap { item in
            item.stockState.map { ListBoard.Staple(itemID: item.id, name: item.name, state: $0, category: item.category) }
        }
    }

    private var suggestions: [String] {
        IngredientAutocomplete.suggestions(whileTyping: newItem, from: items.map(\.name))
    }

    var body: some View {
        NavigationStack {
            List {
                if let storeRuns {
                    StoreRunSection(store: storeRuns, me: household.me, members: household.members)
                }
                addSection
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
                onTheList
                runningLow
                Section {
                    NavigationLink { KeepOnHandView() } label: {
                        Label("Keep on hand", systemImage: "basket")
                    }
                } footer: {
                    Text("Staples you never want to run out of. Anyone can mark them low or out.")
                }
                Section {
                    NavigationLink { FreezerView() } label: {
                        Label("Freezer stash", systemImage: "snowflake")
                    }
                } footer: {
                    Text("Dinners cooked ahead, with the date they were made.")
                }
            }
            .navigationTitle("Lists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Shop", systemImage: "cart") { shopping = true }
                        .disabled(!canShop)
                }
            }
            .refreshable {
                await sync?.pull()
                await storeRuns?.load()
            }
            .task(id: household.household?.id) {
                guard let householdID = household.household?.id else { return }
                if storeRuns?.householdID != householdID {
                    storeRuns = StoreRunStore(householdID: householdID, client: storeRunClient)
                }
                await storeRuns?.load()
            }
            .sheet(item: $openItem) { item in
                ItemSheet(item: item, canRecategorize: canRecategorize, client: itemClient) { await sync?.pull() }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $shopping) { storeMode }
            #else
            .sheet(isPresented: $shopping) { storeMode.frame(minWidth: 420, minHeight: 560) }
            #endif
        }
    }

    @ViewBuilder
    private var storeMode: some View {
        if let householdID = household.household?.id { StoreModeView(householdID: householdID, run: storeRuns?.run) }
    }

    /// Open while there's something to buy, or a trip is still in progress (to finish it).
    private var canShop: Bool {
        !ListBoard.onTheList(entries).isEmpty
            || household.household.map { ShoppingTrip.inProgress($0.id) } == true
    }

    private var canRecategorize: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    // MARK: - Sections

    private var addSection: some View {
        Section {
            TextField("Add an item", text: $newItem)
                .onSubmit { Task { await add() } }
                .submitLabel(.done)
            ForEach(suggestions, id: \.self) { suggestion in
                Button { newItem = IngredientAutocomplete.completing(newItem, with: suggestion) } label: {
                    Label(suggestion, systemImage: "text.badge.plus")
                }
            }
            Toggle("For tonight", isOn: $forTonight)
        } footer: {
            Text("Goes on the quick list. Several at once: separate them with commas.")
        }
    }

    @ViewBuilder
    private var onTheList: some View {
        let open = ListBoard.onTheList(entries)
        Section("On the list") {
            if open.isEmpty {
                Text("Nothing to buy. Approve the week or add an item.").foregroundStyle(.secondary)
            }
            ForEach(open) { entry in
                Button { openItem = details(entry) } label: { ListEntryRow(entry: entry) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the item's note, aisle, and keep on hand")
                    .swipeActions(edge: .leading) {
                        Button("Got it", systemImage: "checkmark") { gotIt(entry) }
                            .tint(Palette.herb)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                    }
                    .contextMenu {
                        Button("Got it", systemImage: "checkmark") { gotIt(entry) }
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                    }
                    .accessibilityAction(named: Text("Got it")) { gotIt(entry) }
                    .accessibilityAction(named: Text("Remove")) { remove(entry) }
            }
        }
    }

    @ViewBuilder
    private var runningLow: some View {
        let low = ListBoard.runningLow(staples, open: entries)
        if !low.isEmpty {
            Section("Staples running low") {
                ForEach(low) { staple in
                    HStack {
                        Label(staple.name, systemImage: staple.category.systemImage)
                        Spacer()
                        Text(staple.state == .out ? "Out" : "Low").font(.foonCaption).foregroundStyle(Palette.caution)
                        Button("Add", systemImage: "plus.circle") {
                            Task { await sync?.addToList(itemID: staple.itemID, list: .quick, source: .staple) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .tint(Palette.paprika)
                        .accessibilityLabel("Add \(staple.name) to the list")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func gotIt(_ entry: ListEntry) {
        Task { await sync?.perform(ListBoard.gotIt(entry)) }
    }

    private func remove(_ entry: ListEntry) {
        Task { await sync?.perform(ListBoard.remove(entry)) }
    }

    /// Known items go on at once, offline too; a brand-new item needs a connection to be created first. Anything
    /// that couldn't be added stays in the field to try again.
    private func add() async {
        let names = IngredientParser.parse(newItem).map(\.name)
        guard let sync, !names.isEmpty, let householdID = household.household?.id else { return }
        newItem = ""
        errorMessage = nil
        let result = await QuickListAdder.add(names, urgency: forTonight ? .tonight : .whenever, items: items,
                                              householdID: householdID, itemClient: itemClient, sync: sync)
        if let message = result.message {
            newItem = result.failed.joined(separator: ", ")
            errorMessage = message
        } else {
            forTonight = false
        }
    }

    private func details(_ entry: ListEntry) -> ItemDetails {
        ItemDetails(id: entry.itemID, name: entry.name, category: entry.category, note: entry.itemNote,
                    keepOnHand: entry.keepOnHand)
    }
}

/// A line: the item with its amount and brand note, the plan's allergy note, and where it came from.
struct ListEntryRow: View {
    let entry: ListEntry
    var large = false
    /// Put on the list during a store run: store mode marks it so whoever's shopping sees what's new.
    var justAdded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ItemLabel(name: entry.name, note: entry.itemNote, quantity: entry.quantity)
                    .font(large ? .title3 : .foonBody)
                if let note = entry.lineNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.foonCaption)
                        .foregroundStyle(Palette.caution)
                }
                ForEach(entry.folded) { other in
                    Text(alsoOn(other)).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if justAdded {
                Chip(text: String(localized: "Just added", comment: "Store mode: put on the list during this store run"),
                     systemImage: "sparkles", tint: Palette.herb)
            }
            if entry.list == .quick {
                Chip(text: entry.urgency == .tonight ? String(localized: "Tonight") : String(localized: "Quick"),
                     tint: entry.urgency == .tonight ? Palette.paprika : .secondary)
            }
        }
        .padding(.vertical, large ? 8 : 2)
        .accessibilityElement(children: .combine)
    }

    /// The item's other line, with its own amount: added to this row's, it could be the same need twice.
    private func alsoOn(_ other: ListEntry) -> String {
        switch (other.list, other.quantity) {
        case (.weekly, let amount?): String(localized: "Also on the week's list: \(amount)", comment: "A row's other line and its amount")
        case (.weekly, nil): String(localized: "Also on the week's list", comment: "A row's other line")
        case (.quick, let amount?): String(localized: "Also on the quick list: \(amount)", comment: "A row's other line and its amount")
        case (.quick, nil): String(localized: "Also on the quick list", comment: "A row's other line")
        }
    }
}

#Preview {
    ListsView()
        .environment(HouseholdStore.preview())
        .environment(\.itemClient, .preview)
        .environment(\.storeRunClient, .preview)
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
}
