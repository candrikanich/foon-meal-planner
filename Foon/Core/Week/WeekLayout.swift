import Foundation

/// How This Week arranges a week: tonight on top, then the nights still ahead, with past nights set aside.
struct WeekLayout: Equatable, Sendable {
    enum Progress: Equatable, Sendable {
        /// No night from tonight on has a meal or quick pick yet.
        case unplanned
        case partlyPlanned
        case planned
    }

    let tonight: WeekNight?
    let upcoming: [WeekNight]
    let past: [WeekNight]

    init(nights: [WeekNight], today: CalendarDay) {
        let sorted = nights.sorted { $0.date < $1.date }
        tonight = sorted.first { $0.date == today }
        upcoming = sorted.filter { $0.date > today }
        past = sorted.filter { $0.date < today }
    }

    /// Tonight and later, in order: the nights that can still be planned.
    var ahead: [WeekNight] { (tonight.map { [$0] } ?? []) + upcoming }

    /// Nights ahead with nothing planned yet.
    var emptyNights: [WeekNight] { ahead.filter { !$0.isPlanned } }

    var progress: Progress {
        let planned = ahead.filter(\.isPlanned).count
        if planned == 0 { return .unplanned }
        return planned == ahead.count ? .planned : .partlyPlanned
    }
}

extension WeekNight {
    var isPlanned: Bool { mealID != nil || quickPick != nil }
}
