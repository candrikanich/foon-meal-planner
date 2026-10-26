enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case week, library, lists, ideas, family

    var id: Self { self }

    var title: String {
        switch self {
        case .week: "This Week"
        case .library: "Library"
        case .lists: "Lists"
        case .ideas: "Ideas"
        case .family: "Family"
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
