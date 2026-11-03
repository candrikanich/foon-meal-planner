import SwiftUI

/// Putting a poll's winner or a rescue idea on tonight. It goes through Swap like any planner's pick, and the same
/// warning comes first when tonight is doubled or from the freezer, since changing it moves another night.
struct TonightChoice: Identifiable {
    let id = UUID()
    let title: String
    let warning: String
    let choice: WeekStore.SwapChoice

    /// The warning to confirm first, or nil when nothing else moves and it can go straight on.
    static func confirmation(title: String, choice: WeekStore.SwapChoice, night: WeekNight,
                             week: [WeekNight]) -> TonightChoice? {
        DoubleIt.changeWarning(for: night, in: week).map { TonightChoice(title: title, warning: $0, choice: choice) }
    }

    /// Swaps the night, then the requests and the freezer follow it. Returns whether it saved; the week store says why
    /// not.
    @MainActor @discardableResult
    static func apply(_ choice: WeekStore.SwapChoice, nightID: UUID, week: WeekStore, ideas: IdeasStore?,
                      freezer: FreezerStore?) async -> Bool {
        guard await week.swap(nightID: nightID, to: choice) else { return false }
        await ideas?.sync(with: week.week, today: week.todayDay, requestNights: week.requestNights,
                          away: week.awayDates)
        if case .freezer = choice { await freezer?.load() }
        return true
    }
}

extension View {
    /// Swap's "this moves another night" confirm, before `apply` puts the choice on tonight.
    func confirmingTonightChoice(_ pending: Binding<TonightChoice?>,
                                 apply: @escaping (WeekStore.SwapChoice) -> Void) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { pending.wrappedValue != nil },
                                                set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { pending in
            Button("Make it tonight's dinner") { apply(pending.choice) }
        } message: { pending in
            Text(pending.warning)
        }
    }
}
