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

    /// A universal link (#85): it opens Foon when it's installed, and getfoon.com's invite page when it isn't. A fresh
    /// install loses the link, so the message carries the code too. getfoon.com redirects to www, and Apple doesn't
    /// follow redirects to the association file, so the link uses www.
    static func link(for code: String) -> URL {
        var link = URLComponents()
        link.scheme = "https"
        link.host = "www.getfoon.com"
        link.path = "/invite"
        link.queryItems = [URLQueryItem(name: "code", value: code)]
        return link.url!
    }

    /// Also takes `foon://invite/<code>`, which invites sent before #85 carry.
    static func code(from url: URL) -> String? {
        let code: String?
        switch (url.scheme, url.host()) {
        case ("foon", "invite"):
            code = url.lastPathComponent
        case ("https", "www.getfoon.com"), ("https", "getfoon.com"):
            guard url.path() == "/invite" else { return nil }
            code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "code" }?.value
        default:
            return nil
        }
        guard let code, !code.isEmpty, code != "/" else { return nil }
        return code
    }

    static func shareMessage(householdName: String, firstName: String, code: String) -> String {
        String(localized: """
            \(firstName), join \(householdName) on Foon, our family dinner planner.
            Open \(link(for: code).absoluteString), or sign in and enter code \(code).
            """, comment: "Invite text: invitee's first name, household name, link, invite code")
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
        case .invalid: String(localized: "That code didn't work. Check it and try again.")
        case .expired: String(localized: "That invite has expired. Ask for a new one.")
        case .used: String(localized: "That invite has already been used. Ask for a new one.")
        case .hasHousehold: String(localized: "You're already in a household. Foon supports one household per person for now.")
        case .rateLimited: String(localized: "Too many tries. Wait 15 minutes and try again.")
        case .needsConsent: String(localized: "This invite needs a parent's OK first. Ask them to send a new one.")
        case .ageMismatch: String(localized: "This invite is for someone else's profile. Ask your family for the right invite.")
        }
    }
}
