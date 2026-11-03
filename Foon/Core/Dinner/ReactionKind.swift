import Foundation

/// How someone felt about a dish (docs/spec.md → After-dinner loop). Always the food, never the cook. Foundation only: the
/// after-dinner card (FoonDinner) shows these too.
enum ReactionKind: String, Codable, CaseIterable, Sendable {
    case favorite
    case good
    case notForMe = "not_for_me"
    case tiredOfIt = "tired_of_it"

    var title: String {
        switch self {
        case .favorite: String(localized: "Favorite")
        case .good: String(localized: "Good")
        case .notForMe: String(localized: "Not for me")
        case .tiredOfIt: String(localized: "Tired of it")
        }
    }

    var systemImage: String {
        switch self {
        case .favorite: "heart.fill"
        case .good: "hand.thumbsup"
        case .notForMe: "hand.thumbsdown"
        case .tiredOfIt: "zzz"
        }
    }
}
