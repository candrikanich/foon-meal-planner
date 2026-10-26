import Foundation

/// Invite codes look like `ANDRI-7KQ4-M9XP`: a cosmetic household prefix and 8 random characters
/// the server checks. People type them in any case, with or without dashes or spaces.
enum InviteCode {
    static func normalized(_ typed: String) -> String {
        String(typed.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    static func isComplete(_ typed: String) -> Bool {
        normalized(typed).count >= 8
    }

    /// Opens Foon when it's installed. A fresh install loses the link, so the message carries the code too.
    static func link(for code: String) -> URL {
        URL(string: "foon://invite/\(code)")!
    }

    static func code(from url: URL) -> String? {
        guard url.scheme == "foon", url.host() == "invite" else { return nil }
        let code = url.lastPathComponent
        return code.isEmpty || code == "/" ? nil : code
    }

    static func shareMessage(householdName: String, firstName: String, code: String) -> String {
        """
        \(firstName), join \(householdName) on Foon, our family dinner planner.
        Open \(link(for: code).absoluteString), or sign in and enter code \(code).
        """
    }
}

/// What happened when someone entered an invite code. Mirrors `redeem_invite`'s statuses.
enum RedeemResult: String, Decodable, Sendable, CaseIterable {
    case claimed
    case invalid
    case expired
    case used
    case hasHousehold = "has_household"
    case rateLimited = "rate_limited"
    case needsConsent = "needs_consent"
    case ageMismatch = "age_mismatch"

    var message: String? {
        switch self {
        case .claimed: nil
        case .invalid: "That code didn't work. Check it and try again."
        case .expired: "That invite has expired. Ask for a new one."
        case .used: "That invite has already been used. Ask for a new one."
        case .hasHousehold: "You're already in a household. Foon supports one household per person for now."
        case .rateLimited: "Too many tries. Wait 15 minutes and try again."
        case .needsConsent: "This invite needs a parent's OK first. Ask them to send a new one."
        case .ageMismatch: "This invite is for an adult's profile. Ask your family for the right invite."
        }
    }
}

/// What a parent agrees to before a kid's invite goes out (COPPA, #12). The version is logged with
/// the consent, so a later wording change can ask parents again.
enum ParentalConsent {
    static let textVersion = "parental-invite-v1"

    static func statement(firstName: String) -> String {
        """
        I'm \(firstName)'s parent or guardian, and I agree to \(firstName) using Foon on their own device. \
        Foon stores what our family enters about \(firstName) (first name, avatar, allergies, and schedule), \
        what \(firstName) adds (requests, ratings, comments, and list items), and an age range from Apple, \
        never a birthdate. It's shared only with this household and never used for ads. \
        I can withdraw this at any time.
        """
    }
}
