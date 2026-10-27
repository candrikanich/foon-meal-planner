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

extension EnvironmentValues {
    /// Switches the app's tab, e.g. the cart on This Week opens Lists. Set by RootTabView.
    @Entry var showTab: (AppTab) -> Void = { _ in }
}
