import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case week, library, lists, ideas, family

    var id: Self { self }

    var title: String {
        switch self {
        case .week: String(localized: "This Week")
        case .library: String(localized: "Library")
        case .lists: String(localized: "Lists")
        case .ideas: String(localized: "Ideas")
        case .family: String(localized: "Family")
        }
    }

    var systemImage: String {
        switch self {
        case .week: "calendar"
        case .library: "book"
        case .lists: "checklist"
        case .ideas: "lightbulb"
        case .family: "person.3"
        }
    }
}

extension ReminderRoute {
    /// Where a tapped notification lands. Everything but Lists, Ideas and Family is on This Week.
    var tab: AppTab {
        switch self {
        case .lists: .lists
        case .ideas: .ideas
        case .family: .family
        case .week, .night, .swap, .dinnerCard, .rate, .checkIn, .roundup: .week
        }
    }
}

/// Switches the app's tab, e.g. the cart on This Week opens Lists. Set by RootTabView.
/// A struct rather than a bare closure so SwiftUI can compare it: every instance does the same job, so readers don't
/// redraw each time RootTabView rebuilds the closure.
struct ShowTabAction: Equatable {
    private let action: (AppTab) -> Void

    init(_ action: @escaping (AppTab) -> Void) {
        self.action = action
    }

    func callAsFunction(_ tab: AppTab) {
        action(tab)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var showTab = ShowTabAction { _ in }
}
