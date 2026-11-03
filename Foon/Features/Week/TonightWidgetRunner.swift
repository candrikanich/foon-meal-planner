import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the Tonight widget's snapshot in step with the week This Week holds (#62). The widget has no network of its own,
/// so it shows what this phone last saw.
struct TonightWidgetRunner: ViewModifier {
    @Environment(HouseholdStore.self) private var household
    let week: Week?

    private struct Key: Equatable {
        let week: Week?
        let settings: HouseholdSettings?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Key(week: week, settings: household.household?.settings), initial: true) {
                write()
            }
    }

    private func write() {
        guard let file = TonightFile.shared, let week, let current = household.household else { return }
        let saved = file.load()
        let snapshot = TonightSnapshot.updated(saved, week: week, householdID: current.id,
                                               settings: current.planningSettings, now: .now)
        // A failed save leaves the widget on the last snapshot it had; the next change to the week tries again.
        guard snapshot != saved, (try? file.save(snapshot)) != nil else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: TonightSnapshot.widgetKind)
        #endif
    }
}
