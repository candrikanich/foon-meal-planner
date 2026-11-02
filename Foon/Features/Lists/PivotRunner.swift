import SwiftData
import SwiftUI

/// Puts what a swapped dish is missing on the quick list. On the root view, since Swap and Plan it open from several tabs, and
/// the plan's store doesn't know the offline list.
struct PivotRunner: ViewModifier {
    @Environment(SyncService.self) private var sync: SyncService?
    @Query(filter: #Predicate<CachedListItem> { $0.checkedAt == nil }) private var openLines: [CachedListItem]
    @Query private var items: [CachedItem]
    let week: WeekStore
    let library: LibraryStore
    let dinner: DinnerStore

    func body(content: Content) -> some View {
        content.onChange(of: week.swappedDish) { _, swap in
            guard let swap else { return }
            // Read now as plain values: a pull replaces the cached rows, and these outlive the moment.
            let stock = Dictionary(items.compactMap { item in item.stockState.map { (item.id, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            let open = openLines.map(\.pivotLine)
            Task { await addGaps(swap, stock: stock, open: open) }
        }
    }

    private func addGaps(_ swap: WeekStore.SwappedDish, stock: [UUID: StockState], open: [PivotGaps.OpenLine]) async {
        guard let sync, let layout = week.layout, let night = week.week?.nights.first(where: { $0.id == swap.nightID }) else { return }
        let outcome = PivotGaps.outcome(night: night, in: layout, logged: Set(dinner.logs.map(\.nightID)),
                                        // Before the first sync, everything would look out of stock.
                                        canTrustStock: sync.lastPulled != nil,
                                        canTrustLibrary: library.hasLoaded && library.lookup != .failed && library.lookup != .retrying,
                                        library: library.meals, stock: stock, allergies: library.allergies, open: open,
                                        today: week.todayDay)
        switch outcome {
        case .nothing:
            return
        case .couldntCheck:
            week.notePivot(PivotGaps.couldntCheckMessage)
        case .add(let gaps, let check):
            let tonight = night.date == week.todayDay
            week.notePivot(PivotGaps.summary(gaps: gaps, check: check, tonight: tonight))
            guard !gaps.isEmpty else { return }
            let planID = week.week?.planID
            for gap in gaps {
                await sync.addToList(itemID: gap.line.itemID, list: .quick, urgency: tonight ? .tonight : .whenever, source: .pivot,
                                     note: gap.line.note, quantity: gap.line.quantity, planID: planID)
            }
            // A dish just added from the starter pack brings items this device hasn't seen.
            await sync.pull()
        }
    }
}

extension CachedListItem {
    var pivotLine: PivotGaps.OpenLine {
        PivotGaps.OpenLine(itemID: itemID, note: note, quantity: quantity, isPivot: sourceRaw == ListItemSource.pivot.rawValue,
                           isTonight: listRaw == ListKind.quick.rawValue && urgencyRaw == ListUrgency.tonight.rawValue, planID: planID)
    }
}
