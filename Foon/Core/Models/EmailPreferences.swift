import Foundation

/// The emails an adult can turn on for themselves (#48): personal, not the household's, and off until they do. Turning
/// one on logs their agreement to its wording (`set_email_preference`); each wording is registered in
/// `agreement_versions`, and a change in what one promises is a new version there and here.
enum EmailOptIn: String, CaseIterable, Identifiable, Sendable {
    case weeklyPlan = "weekly_plan"
    case foundingUpdates = "founding_updates"

    var id: String { rawValue }

    var textVersion: String {
        switch self {
        case .weeklyPlan: "weekly-plan-email-v1"
        case .foundingUpdates: "founding-updates-v1"
        }
    }

    var title: String {
        switch self {
        case .weeklyPlan: String(localized: "Weekly plan email", comment: "Family → Email: the switch's name")
        case .foundingUpdates: String(localized: "Founding-family updates", comment: "Family → Email: the switch's name")
        }
    }

    /// The one line under the switch.
    var explanation: String {
        switch self {
        case .weeklyPlan:
            String(localized: "The week's dinners, by email, when the week is approved.",
                   comment: "Family → Email: what the weekly plan email is")
        case .foundingUpdates:
            String(localized: "Now and then, news about Foon for founding families.",
                   comment: "Family → Email: what founding-family updates are")
        }
    }

    /// What they agree to when they turn it on.
    var statement: String {
        switch self {
        case .weeklyPlan:
            String(localized: """
            When your family's week is approved, Foon emails you its dinners at the email Apple gave for your account. \
            It never includes allergies. Turn it off here anytime, or with the link in any of the emails.
            """, comment: """
                What an adult agrees to when turning on the weekly plan email. Must say exactly what the English says; \
                see EmailOptIn.textVersion.
                """)
        case .foundingUpdates:
            String(localized: """
            Now and then, Foon emails you news for founding families: what's new, what's coming, and offers. They go to \
            the email Apple gave for your account. Turn them off here anytime, or unsubscribe with the link in any of them.
            """, comment: """
                What an adult agrees to when turning on founding-family updates. Must say exactly what the English \
                says; see EmailOptIn.textVersion.
                """)
        }
    }
}

/// `my_email_preferences`: the caller's own switches, whether they may turn one on (an adult in a household), and
/// whether Foon sends email at all yet.
struct EmailPreferences: Decodable, Equatable, Sendable {
    var weeklyPlan = false
    var foundingUpdates = false
    var canOptIn = false
    var available = false

    enum CodingKeys: String, CodingKey {
        case weeklyPlan = "weekly_plan"
        case foundingUpdates = "founding_updates"
        case canOptIn = "can_opt_in"
        case available
    }

    func isOn(_ email: EmailOptIn) -> Bool {
        switch email {
        case .weeklyPlan: weeklyPlan
        case .foundingUpdates: foundingUpdates
        }
    }

    /// Shown while Foon sends email and they may opt in, and always while one is on, so it can be turned off.
    var isShown: Bool {
        (available && canOptIn) || weeklyPlan || foundingUpdates
    }
}
