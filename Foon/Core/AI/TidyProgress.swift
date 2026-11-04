import Foundation

/// What Foon says while this device tidies a shared recipe (#256). People will wait for a better recipe when they're
/// told what's happening, so the message moves on as time passes. It only says true things, never praises the food,
/// and never says how the tidying's done.
enum TidyProgress {
    enum Stage: Int, CaseIterable, Comparable, Sendable {
        case reading
        case ingredients
        case lotGoingOn
        case almostThere

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// "Almost there" waits until the tidy-up is at most this far from landing or giving up, so it's always true.
    private static let almostLeft: Duration = .seconds(10)

    /// When each stage begins, in order.
    private static func starts(limit: Duration) -> [(stage: Stage, at: Duration)] {
        let lotGoingOn: Duration = .seconds(12)
        return [(.reading, .zero), (.ingredients, .seconds(5)), (.lotGoingOn, lotGoingOn),
                (.almostThere, max(limit - almostLeft, lotGoingOn + .seconds(1)))]
    }

    static func stage(after elapsed: Duration, limit: Duration) -> Stage {
        starts(limit: limit).last { $0.at <= elapsed }?.stage ?? .reading
    }

    /// How long until the message changes; nil once it's the last one.
    static func nextChange(after elapsed: Duration, limit: Duration) -> Duration? {
        starts(limit: limit).first { $0.at > elapsed }.map { $0.at - elapsed }
    }

    static func message(_ stage: Stage) -> String {
        switch stage {
        case .reading: String(localized: "Reading the recipe…")
        case .ingredients: String(localized: "Sorting out the ingredients…")
        case .lotGoingOn: String(localized: "This one's got a lot going on. Worth the wait…")
        case .almostThere: String(localized: "Almost there…")
        }
    }

    static var detail: String {
        String(localized: "Foon is tidying this up on this device, so you don't have to fix it by hand.")
    }
    static var skip: String { String(localized: "Don't wait, I'll finish it myself") }
    /// Over the rough draft when the tidy-up ran out of time or found nothing it could use.
    static var stubborn: String {
        String(localized: "This one's being stubborn. Here's what Foon found. Check the amounts.")
    }
    /// For VoiceOver, when the tidied recipe replaces the card.
    static var landed: String { String(localized: "All tidied up. Check it over before you save it.") }

    static var allCopy: [String] {
        Stage.allCases.map(message) + [detail, skip, stubborn, landed]
    }
}
