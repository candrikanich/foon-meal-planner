import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Store mode: the whole trip by aisle in walking order (non-food last), big tap targets, checked items sink into
/// the cart, and the screen stays awake. Everything works offline; a second shopper's check-offs arrive over
/// Realtime when there's signal. "Couldn't find it" moves an item to the quick list for next time.
struct StoreModeView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    @Query private var lines: [CachedListItem]
    @Query private var items: [CachedItem]
    /// The trip in progress, saved so closing store mode mid-trip keeps the cart and skipped items.
    @AppStorage private var savedTrip: String
    @State private var finished: ListBoard.Summary?

    init(householdID: UUID) {
        _savedTrip = AppStorage(wrappedValue: "", ShoppingTrip.storageKey(householdID))
    }

    private var entries: [ListEntry] { ListEntry.entries(lines: lines, items: items) }

    private var trip: ShoppingTrip { ShoppingTrip(rawValue: savedTrip) ?? ShoppingTrip(start: .now) }

    var body: some View {
        let board = ListBoard.store(entries, tripStart: trip.start, skipped: trip.skipped)
        NavigationStack {
            List {
                if board.aisles.isEmpty {
                    Section {
                        Label("Everything's in the cart", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.herb)
                    }
                }
                ForEach(board.aisles) { aisle in
                    Section {
                        ForEach(aisle.entries) { entry in
                            Button { check(entry, true) } label: { row(entry, checked: false) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("Couldn't find it", systemImage: "questionmark.circle") {
                                        Task { await couldntFind(entry) }
                                    }
                                    .tint(Palette.caution)
                                }
                                .contextMenu {
                                    Button("Couldn't find it", systemImage: "questionmark.circle") {
                                        Task { await couldntFind(entry) }
                                    }
                                }
                                .accessibilityHint("Marks it in the cart")
                                .accessibilityActions {
                                    Button("Couldn't find it") { Task { await couldntFind(entry) } }
                                }
                        }
                    } header: {
                        Label(aisle.category.title, systemImage: aisle.category.systemImage).font(.foonHeadline)
                    }
                }
                if !board.nextTime.isEmpty {
                    Section {
                        ForEach(board.nextTime) { entry in
                            ListEntryRow(entry: entry).opacity(0.6)
                        }
                    } header: {
                        Text("For next time")
                    } footer: {
                        Text("On the quick list for the next trip.")
                    }
                }
                if !board.cart.isEmpty {
                    Section("In the cart") {
                        ForEach(board.cart) { entry in
                            Button { check(entry, false) } label: { row(entry, checked: true) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Takes it out of the cart")
                        }
                    }
                }
            }
            .navigationTitle("Store mode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish trip") { Task { await finish() } }
                }
            }
            .alert(summaryTitle, isPresented: Binding(get: { finished != nil }, set: { if !$0 { finished = nil } })) {
                Button("Done") { dismiss() }
            } message: {
                Text(summaryMessage)
            }
        }
        .onAppear {
            keepAwake(true)
            if ShoppingTrip(rawValue: savedTrip) == nil { savedTrip = ShoppingTrip(start: .now).rawValue }
        }
        .onDisappear { keepAwake(false) }
    }

    private func row(_ entry: ListEntry, checked: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(checked ? Palette.herb : Palette.paprika)
            ListEntryRow(entry: entry, large: true)
                .opacity(checked ? 0.5 : 1)
                .strikethrough(checked)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func check(_ entry: ListEntry, _ checked: Bool) {
        let changes = checked ? ListBoard.gotIt(entry) : [.setChecked(listItemID: entry.lineID, checked: false)]
        Task { for change in changes { await sync?.perform(change) } }
    }

    /// The item goes to the quick list for next time, and out of the aisles for this trip.
    private func couldntFind(_ entry: ListEntry) async {
        guard let sync, let householdID = household.household?.id else { return }
        let newLine = UUID()
        var updated = trip
        if entry.list == .quick {
            updated.skipped.insert(entry.lineID)
        } else {
            updated.skipped.insert(newLine)
            for change in ListBoard.couldntFind(entry, householdID: householdID, newLineID: newLine) {
                await sync.perform(change)
            }
        }
        savedTrip = updated.rawValue
    }

    private func finish() async {
        let current = trip
        let summary = ListBoard.summary(entries, tripStart: current.start, skipped: current.skipped)
        for change in ListBoard.finishTrip(entries, tripStart: current.start) {
            await sync?.perform(change)
        }
        savedTrip = ""
        finished = summary
    }

    private var summaryTitle: String {
        guard let finished else { return "" }
        return finished.got == 1 ? String(localized: "Got 1 item") : String(localized: "Got \(finished.got) items")
    }

    private var summaryMessage: String {
        guard let finished else { return "" }
        switch finished.left {
        case 0: return String(localized: "Nothing left on the list.")
        case 1: return String(localized: "1 item is still on the list for next time.")
        default: return String(localized: "\(finished.left) items are still on the list for next time.")
        }
    }

    /// The list stays on screen through the whole trip.
    private func keepAwake(_ awake: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}

#Preview {
    StoreModeView(householdID: Household.sample.id)
        .environment(HouseholdStore.preview())
        .modelContainer(try! SyncService.inMemoryContainer())
}
