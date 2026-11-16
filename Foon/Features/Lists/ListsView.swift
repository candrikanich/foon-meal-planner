import SwiftData
import SwiftUI
import TipKit

/// The household's lists (docs/spec.md → Shopping and pantry), read from the offline cache so they work with no
/// signal: add an item, what's on the list (tonight first, then the week, then the rest), and staples running low.
/// Shop opens store mode. Everyone at home works the list.
struct ListsView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(HouseholdStore.self) private var household
    @Environment(SubscriptionStore.self) private var subscription
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
    @Environment(\.receiptClient) private var receiptClient
    @State private var receiptScan: ReceiptScanStore?
    @Environment(\.forwardedReceiptClient) private var forwardedClient
    @State private var forwarded: ForwardedReceiptsStore?
    @Environment(\.scenePhase) private var scenePhase
    private let storeModeTip = StoreModeTip()

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
                if canEditLists { addSection }
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                onTheList
                runningLow
                if let forwarded {
                    ForwardedReceiptsSection(receipts: forwarded.receipts, canReview: canEditLists) { receipt in
                        review(receipt)
                    }
                }
                Section {
                    Button { scanReceipt() } label: {
                        Label("Scan a receipt", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(household.household == nil || !canEditLists)
                    .tint(Palette.paprika)
                    if household.isAdult, let householdID = household.household?.id, let me = household.me {
                        NavigationLink {
                            ReceiptForwardingView(
                                store: ReceiptForwardingStore(householdID: householdID, memberID: me.id,
                                                              client: forwardedClient),
                                canEdit: canEditLists
                            )
                        } label: {
                            Label("Forward receipts by email", systemImage: "envelope")
                        }
                    }
                } footer: {
                    Text("Marks what you bought, checks it off the lists, and puts staples back in stock.")
                }
                .listRowBackground(Palette.cardSurface)
                Section {
                    NavigationLink { KeepOnHandView() } label: {
                        Label("Keep on hand", systemImage: "basket").foregroundStyle(Palette.ink)
                    }
                    .accessibilityHint("Staples you never want to run out of. Anyone can mark them low or out.")
                    NavigationLink { FreezerView() } label: {
                        Label("Freezer stash", systemImage: "snowflake").foregroundStyle(Palette.ink)
                    }
                    .accessibilityHint("Dinners cooked ahead, with the date they were made.")
                }
                .tint(Palette.paprika)
                .listRowBackground(Palette.cardSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.cream)
            .navigationTitle("Lists")
            .navigationSubtitle(ListBoard.pickUpSubtitle(count: ListBoard.onTheList(entries).count))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Shop", systemImage: "cart") { openStoreMode() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.paprika)
                        .disabled(!canShop)
                        .popoverTip(offersStoreModeTip ? storeModeTip : nil)
                }
            }
            .refreshable {
                await sync?.pull()
                await storeRuns?.load()
                await forwarded?.load()
            }
            .task(id: household.household?.id) {
                guard let householdID = household.household?.id else { return }
                if storeRuns?.householdID != householdID {
                    storeRuns = StoreRunStore(householdID: householdID, client: storeRunClient)
                }
                if forwarded?.householdID != householdID {
                    forwarded = ForwardedReceiptsStore(householdID: householdID, client: forwardedClient)
                }
                await storeRuns?.load()
                await forwarded?.load()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await forwarded?.load() }
            }
            .sheet(item: $openItem) { item in
                ItemSheet(item: item, canRecategorize: canRecategorize, client: itemClient) { await sync?.pull() }
            }
            .sheet(item: $receiptScan, onDismiss: { Task { await forwarded?.load() } }) { scan in
                ReceiptScanView(store: scan)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 560)
                    #endif
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

    private var offersStoreModeTip: Bool {
        TipRules.eligible(onMac: FoonTips.onMac, canShop: canShop).contains(.storeMode)
    }

    private func openStoreMode() {
        storeModeTip.invalidate(reason: .actionPerformed)
        shopping = true
    }

    /// Open while there's something to buy, or a trip is still in progress (to finish it).
    private var canShop: Bool {
        !ListBoard.onTheList(entries).isEmpty
            || household.household.map { ShoppingTrip.inProgress($0.id) } == true
    }

    /// Adding and removing items stop when the household has lapsed; checking things off on a trip keeps working.
    private var canEditLists: Bool { subscription.access.allowsEditing }

    private var canRecategorize: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    // MARK: - Sections

    private var addSection: some View {
        Section {
            addRow
            ForEach(suggestions, id: \.self) { suggestion in
                Button { newItem = IngredientAutocomplete.completing(newItem, with: suggestion) } label: {
                    Label(suggestion, systemImage: "text.badge.plus")
                }
                .tint(Palette.paprika)
            }
            Toggle("For tonight", isOn: $forTonight)
                .tint(Palette.herb)
        } footer: {
            Text("Goes on the quick list. Several at once: separate them with commas.")
        }
        .listRowBackground(Palette.cardSurface)
    }

    private var canAdd: Bool { !IngredientParser.parse(newItem).isEmpty }

    /// Return still submits; the button is for anyone who doesn't reach for it. At AX sizes it drops below the field.
    private var addRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { addField; addButton }
            VStack(alignment: .leading, spacing: 8) { addField; addButton }
        }
    }

    private var addField: some View {
        TextField("Add an item", text: $newItem)
            .onSubmit { Task { await add() } }
            .submitLabel(.done)
    }

    private var addButton: some View {
        Button("Add") { Task { await add() } }
            .buttonStyle(.pill(.tinted))
            .disabled(!canAdd)
    }

    @ViewBuilder
    private var onTheList: some View {
        let open = ListBoard.onTheList(entries)
        Section {
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
                        if canEditLists {
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                        }
                    }
                    .contextMenu {
                        Button("Got it", systemImage: "checkmark") { gotIt(entry) }
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                            .disabled(!canEditLists)
                    }
                    .accessibilityAction(named: Text("Got it")) { gotIt(entry) }
                    .accessibilityAction(named: Text("Remove")) { if canEditLists { remove(entry) } }
            }
        } header: {
            SectionHeader("On the list").textCase(nil)
        } footer: {
            if !open.isEmpty {
                Text("Swipe an item for \u{201C}Got it\u{201D} or \u{201C}Remove\u{201D}.")
            }
        }
        .listRowBackground(Palette.cardSurface)
    }

    @ViewBuilder
    private var runningLow: some View {
        let low = ListBoard.runningLow(staples, open: entries)
        if !low.isEmpty {
            Section {
                ForEach(low) { staple in
                    stapleRow(staple)
                }
            } header: {
                SectionHeader("Staples running low").textCase(nil)
            }
            .listRowBackground(Palette.cardSurface)
        }
    }

    private func stapleRow(_ staple: ListBoard.Staple) -> some View {
        let state = Text(staple.state == .out ? "Out" : "Low").font(.foonCaption).foregroundStyle(Palette.caution)
        let add = Button("Add") {
            Task { await sync?.addToList(itemID: staple.itemID, list: .quick, source: .staple) }
        }
        .buttonStyle(.pill(.tinted))
        .disabled(!canEditLists)
        .accessibilityLabel("Add \(staple.name) to the list")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(staple.name, systemImage: staple.category.systemImage)
                Spacer(minLength: 8)
                state
                add
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(staple.name, systemImage: staple.category.systemImage)
                HStack(spacing: 12) { state; add }
            }
        }
    }

    // MARK: - Actions

    private func gotIt(_ entry: ListEntry) {
        Task { await sync?.perform(ListBoard.gotIt(entry)) }
    }

    /// A fresh scan each time, so nothing from the last receipt is left over.
    private func scanReceipt() {
        guard let householdID = household.household?.id else { return }
        receiptScan = ReceiptScanStore(householdID: householdID, client: receiptClient, itemClient: itemClient)
    }

    /// A forwarded receipt email opens the same review as a photo, without the photo.
    private func review(_ receipt: ForwardedReceipt) {
        guard let householdID = household.household?.id else { return }
        receiptScan = ReceiptScanStore(householdID: householdID, client: receiptClient, itemClient: itemClient,
                                       source: .forwarded(receipt), forwardedClient: forwardedClient)
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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { text; chips; nightLabel }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The item comes first: a long night label wraps before it squeezes the name.
                    text.layoutPriority(1)
                    Spacer(minLength: 8)
                    chips
                    nightLabel
                }
            }
        }
        .padding(.vertical, large ? 8 : 2)
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
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
    }

    /// The nights that need it, trailing and quiet. It keeps every night and wraps rather than clips (#351's device review).
    @ViewBuilder
    private var nightLabel: some View {
        if let label = entry.nightLabel {
            Text(label.text)
                .font(large ? .foonBody : .foonCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(label.spoken)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if justAdded {
            Chip(text: String(localized: "Just added", comment: "Store mode: put on the list during this store run"),
                 systemImage: "sparkles", tint: Palette.herb)
        }
        if entry.list == .quick {
            let tonight = entry.urgency == .tonight
            Chip(text: tonight ? String(localized: "Tonight") : String(localized: "Quick"),
                 systemImage: tonight ? "flame.fill" : "bolt.fill",
                 tint: tonight ? Palette.paprika : .secondary)
        }
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

@MainActor
private func listsPreview() -> some View {
    ListsView()
        .environment(SubscriptionStore(householdID: Household.sample.id, client: .preview(), storeKit: .preview))
        .environment(HouseholdStore.preview())
        .environment(\.itemClient, .preview)
        .environment(\.storeRunClient, .preview)
        .environment(\.receiptClient, .preview())
        .environment(\.forwardedReceiptClient, .preview(waiting: ReceiptFixtures.forwarded))
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
}

private func previewEntry(_ name: String, quantity: String? = nil, list: ListKind = .weekly,
                          urgency: ListUrgency = .whenever, note: String? = nil,
                          nights: [ListNightRef] = [], checkedAt: Date? = nil) -> ListEntry {
    ListEntry(lineID: UUID(), itemID: UUID(), name: name, list: list, urgency: urgency, quantity: quantity,
              lineNote: note, itemNote: nil, category: .pantry, checkedAt: checkedAt, keepOnHand: false, nights: nights)
}

private func night(_ date: String, _ meal: String?) -> ListNightRef {
    ListNightRef(date: date, mealName: meal)
}

private struct ListRowsPreview: View {
    var body: some View {
        List {
            ListEntryRow(entry: previewEntry("Ground beef", quantity: "2 lb", list: .quick, urgency: .tonight))
            ListEntryRow(entry: previewEntry("Tortillas", quantity: "1", list: .quick))
            ListEntryRow(entry: previewEntry("Bell peppers", quantity: "3"))
            ListEntryRow(entry: previewEntry("Extra-virgin olive oil, cold pressed, the big tin from the Italian shop",
                                             quantity: "2 litres", list: .quick, urgency: .tonight,
                                             note: "Contains tree nuts: Nora, Owen"))
            ListEntryRow(entry: previewEntry("Onions", quantity: "2", nights: [night("2026-11-17", "Chili")]))
            ListEntryRow(entry: previewEntry("Cheddar", nights: [night("2026-11-17", "Chili"), night("2026-11-20", "Tacos")]))
            ListEntryRow(entry: previewEntry("Garlic", nights: [night("2026-11-17", "Chili"), night("2026-11-19", nil),
                                                                night("2026-11-20", "Tacos")]))
            ListEntryRow(entry: previewEntry("Cilantro", quantity: "1 bunch", list: .quick, urgency: .tonight,
                                             nights: [night("2026-11-18", "Slow-roasted pork shoulder with pineapple salsa")]))
            ListEntryRow(entry: previewEntry("Limes", nights: [night("2026-11-20", "Tacos")], checkedAt: .now))
        }
        .scrollContentBackground(.hidden)
        .background(Palette.cream)
        .listRowBackground(Palette.cardSurface)
    }
}

#Preview("Lists") { listsPreview() }
#Preview("Lists · Dark") { listsPreview().preferredColorScheme(.dark) }
#Preview("Lists · AX3") { listsPreview().dynamicTypeSize(.accessibility3) }
#Preview("Rows") { ListRowsPreview() }
#Preview("Rows · Dark") { ListRowsPreview().preferredColorScheme(.dark) }
#Preview("Rows · AX3 long text") { ListRowsPreview().dynamicTypeSize(.accessibility3) }
