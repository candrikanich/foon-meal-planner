import Foundation

/// Emailing an adult's invite (#48 PR B): a parent types the adult's address, and `account-email`'s invite door emails
/// the link and the code. The address goes with this one request and is kept nowhere, on the device or the server.
struct InviteEmailRequest: Encodable, Equatable, Sendable {
    /// The function's door for it: `account-email?invite=1`.
    static let function = "account-email"
    static let query = [URLQueryItem(name: "invite", value: "1")]

    let memberID: UUID
    let code: String
    let email: String

    enum CodingKeys: String, CodingKey {
        case code, email
        case memberID = "memberId"
    }

    init(memberID: UUID, code: String, email: String) {
        self.memberID = memberID
        self.code = code
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why an invite email didn't go. Mirrors `account-email`'s invite answers.
enum InviteEmailError: Error, Equatable, Sendable {
    case badEmail
    case notSignedIn
    case notAParent
    /// Foon never emails kids; their invite needs a parent's consent and goes by the share sheet.
    case kid
    /// The profile was claimed or removed since.
    case alreadyJoined
    /// The code was replaced by inviting again, or expired.
    case inviteChanged
    /// One of the send limits; the server never says which.
    case rateLimited
    case sendFailed
    /// Account email isn't turned on yet.
    case emailOff
    case tryAgain

    init(status: Int, body: Data) {
        let code = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        self = switch (status, code) {
        case (400, "bad_email"): .badEmail
        case (401, _): .notSignedIn
        case (403, _): .notAParent
        case (409, "kid"): .kid
        case (409, "not_invitable"): .alreadyJoined
        case (409, _): .inviteChanged
        case (429, _): .rateLimited
        case (502, _): .sendFailed
        case (503, _): .emailOff
        default: .tryAgain
        }
    }

    var message: String {
        switch self {
        case .badEmail: String(localized: "That email doesn't look right. Check it and try again.")
        case .notSignedIn: String(localized: "Your sign-in has ended. Sign in again, then try again.")
        case .notAParent: String(localized: "Only a parent in the family can send this invite.")
        case .kid: String(localized: "Foon emails invites to adults only. Share a kid's invite another way.")
        case .alreadyJoined: String(localized: "They've already joined, so there's nothing to send.")
        case .inviteChanged: String(localized: "This code was replaced or has expired. Invite again for a new one.")
        case .rateLimited: String(localized: "Try again in a little while.")
        case .emailOff: String(localized: "Foon doesn't send email yet.")
        case .sendFailed, .tryAgain:
            String(localized: "Couldn't send the email. Check your connection and try again.")
        }
    }
}
