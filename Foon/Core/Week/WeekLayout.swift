import Foundation

/// How This Week arranges a week: tonight on top, then the nights still ahead, with past nights set aside.
struct WeekLayout: Equatable, Sendable {
    enum Progress: Equatable, Sendable {
        /// No night from tonight on that can be planned has a meal or quick pick yet.
        case unplanned
        case partlyPlanned
        case planned
    }

    let tonight: WeekNight?
    let upcoming: [WeekNight]
    let past: [WeekNight]
    private let away: [AwayDates]

    init(nights: [WeekNight], today: CalendarDay, away: [AwayDates] = []) {
        self.away = away
        let sorted = nights.sorted { $0.date < $1.date }
        tonight = sorted.first { $0.date == today }
        upcoming = sorted.filter { $0.date > today }
        past = sorted.filter { $0.date < today }
    }

    /// Tonight and later, in order: the nights that can still be planned.
    var ahead: [WeekNight] { (tonight.map { [$0] } ?? []) + upcoming }

    /// Nights ahead outside the household's away dates: the ones to plan and shop for.
    var plannable: [WeekNight] { ahead.filter { night in !away.contains { $0.contains(night.date) } } }

    /// Plannable nights with nothing planned yet.
    var emptyNights: [WeekNight] { plannable.filter { !$0.isPlanned } }

    var progress: Progress {
        let plannable = plannable
        let planned = plannable.filter(\.isPlanned).count
        if planned == 0 { return .unplanned }
        return planned == plannable.count ? .planned : .partlyPlanned
    }
}

extension WeekNight {
    var isPlanned: Bool { mealID != nil || quickPick != nil }
}
