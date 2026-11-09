import Foundation

/// A parent's request for a kid's consent by email (COPPA email plus, #275): a row of `parental_consent_requests`.
/// Only the server writes these; the app reads them to know which step the invite section shows.
struct ParentalConsentRequest: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable {
        /// Email 1 is out, with no answer yet.
        case pending
        /// The parent agreed, but the confirming email hasn't gone out yet.
        case consented
        /// The confirming email went out and the consent is active (or was, until withdrawn).
        case confirmed
        case refused
        case cancelled
        case expired

        /// A status this version doesn't know reads as ended, which offers a new email.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .cancelled
        }
    }

    enum EmailSource: String, Decodable, Sendable {
        /// The address on the parent's Sign in with Apple account.
        case account
        /// One the parent typed, because their account had none Foon trusts.
        case typed

        /// A source this version doesn't know reads as the account's, which only changes the wording.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = EmailSource(rawValue: raw) ?? .account
        }
    }

    /// Exactly the columns parents may read: `select *` is refused, since the hashes and typed email aren't granted.
    static let columns = """
        id, household_id, member_id, requested_by, status, email_source, text_version, token_sent_at, expires_at, \
        decided_at, confirmed_at, ended_at, created_at
        """

    let id: UUID
    let householdID: UUID
    let memberID: UUID
    /// The auth user id of the parent who asked.
    let requestedBy: UUID
    let status: Status
    let emailSource: EmailSource?
    /// Null until the first email is out.
    let expiresAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case householdID = "household_id"
        case memberID = "member_id"
        case requestedBy = "requested_by"
        case emailSource = "email_source"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    /// The daily job ends lapsed requests, so one still waiting past its link's life has expired already.
    func isOpen(now: Date) -> Bool {
        guard status == .pending || status == .consented else { return false }
        return expiresAt.map { $0 >= now } ?? true
    }
}

/// Where email 1 went, as the invite section says it.
enum ConsentEmailAddress: Equatable, Sendable {
    case address(String)
    /// A Sign in with Apple relay address, which means nothing to read: say what it is instead.
    case hideMyEmail
    /// Known only from the request row, which never carries the address.
    case accountEmail
    case typedEmail

    static let relayDomain = "@privaterelay.appleid.com"

    init(sentTo email: String) {
        self = email.lowercased().hasSuffix(Self.relayDomain) ? .hideMyEmail : .address(email)
    }

    init(source: ParentalConsentRequest.EmailSource?) {
        self = source == .typed ? .typedEmail : .accountEmail
    }
}

/// What a kid's invite section offers, decided as #275's contract says: an active consent first, then the newest
/// request for the kid.
enum ParentalConsentStep: Equatable, Sendable {
    /// Who asked, so the section never tells one parent what another one did.
    enum Asker: Equatable, Sendable {
        case me
        case otherParent(firstName: String?)
    }

    /// Nothing asked yet: **Email me**.
    case emailMe
    /// Waiting on the parent to agree in the email: **Send again**.
    case checkEmail(sentTo: ConsentEmailAddress, askedBy: Asker)
    /// They agreed, and the confirming email hasn't gone out yet: they finish from the email, so no button.
    case almostDone(askedBy: Asker)
    /// They said no in the email: **Ask again**.
    case refused(askedBy: Asker)
    /// The link lapsed, the request was replaced or ended, or consent was withdrawn: **Send a new email**.
    case sendNewEmail
    /// Consent is active: the normal Invite button.
    case invite

    static func decide(
        hasConsent: Bool,
        latest: ParentalConsentRequest?,
        me: UUID,
        sentAddress: String?,
        parentName: (UUID) -> String?,
        now: Date
    ) -> ParentalConsentStep {
        if hasConsent { return .invite }
        guard let latest else { return .emailMe }
        let asker: Asker = latest.requestedBy == me ? .me : .otherParent(firstName: parentName(latest.requestedBy))
        if latest.isOpen(now: now) {
            if latest.status == .consented { return .almostDone(askedBy: asker) }
            let sentTo = asker == .me
                ? sentAddress.map(ConsentEmailAddress.init(sentTo:)) ?? ConsentEmailAddress(source: latest.emailSource)
                : ConsentEmailAddress(source: latest.emailSource)
            return .checkEmail(sentTo: sentTo, askedBy: asker)
        }
        return latest.status == .refused ? .refused(askedBy: asker) : .sendNewEmail
    }
}

/// What `parental-consent` answered a parent's ask (#275 contract, section 1).
enum ParentalConsentAnswer: Equatable, Sendable {
    case sent(requestID: UUID, email: String, source: ParentalConsentRequest.EmailSource)
    case alreadyConsented
    /// The account has no email Foon trusts: ask the parent for one and send again with it.
    case noEmail

    /// Reads a response the function sent, success or not; an error status throws its `ParentalConsentError`.
    static func decode(status: Int, body: Data) throws -> ParentalConsentAnswer {
        guard (200..<300).contains(status) else { throw ParentalConsentError(status: status, body: body) }
        let reply = try JSONDecoder().decode(Reply.self, from: body)
        switch reply.result {
        case "sent":
            guard let requestID = reply.requestId, let email = reply.email else { throw ParentalConsentError.tryAgain }
            return .sent(requestID: requestID, email: email, source: reply.emailSource ?? .account)
        case "already_consented": return .alreadyConsented
        case "no_email": return .noEmail
        default: throw ParentalConsentError.tryAgain
        }
    }

    private struct Reply: Decodable {
        let result: String
        let requestId: UUID?
        let email: String?
        let emailSource: ParentalConsentRequest.EmailSource?
    }
}

/// Why asking for consent didn't send an email.
enum ParentalConsentError: Error, Equatable, Sendable {
    case badRequest
    case badEmail
    case notSignedIn
    case notAParent
    case notEligible
    /// One of the send limits; the server never says which.
    case rateLimited
    case sendFailed
    /// Email isn't set up on the server.
    case emailOff
    case tryAgain

    init(status: Int, body: Data) {
        let code = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        self = switch (status, code) {
        case (400, "bad_email"): .badEmail
        case (400, _): .badRequest
        case (401, _): .notSignedIn
        case (403, _): .notAParent
        case (409, _): .notEligible
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
        case .notAParent: String(localized: "Only a parent in the family can ask for this.")
        case .notEligible: String(localized: "This profile can't be invited this way any more.")
        case .rateLimited: String(localized: "Try again in a little while.")
        case .emailOff: String(localized: "Foon can't send email right now. Try again later.")
        case .badRequest, .sendFailed, .tryAgain:
            String(localized: "Couldn't send the email. Check your connection and try again.")
        }
    }
}

/// Each kid's consent email as this parent's app knows it: the newest request from the server, plus what this device
/// heard back when it last asked. Pure, so every step can be tested without a store.
struct ParentalConsentBook: Equatable, Sendable {
    /// The newest request for each kid.
    private(set) var latest: [UUID: ParentalConsentRequest] = [:]
    /// Where this device's last email 1 for each kid went; the request rows never carry the address.
    private var sentAddresses: [UUID: String] = [:]
    /// Kids whose next ask needs an address typed, since the parent's account has none Foon trusts.
    private var typedEmailNeeded: Set<UUID> = []
    /// A calm word on the last ask for each kid, such as "Try again in a little while."
    private var notices: [UUID: String] = [:]

    /// Consent links last 7 days from their email.
    static let linkLife: TimeInterval = 7 * 24 * 60 * 60

    func step(
        for memberID: UUID, hasConsent: Bool, me: UUID, now: Date, parentName: (UUID) -> String?
    ) -> ParentalConsentStep {
        ParentalConsentStep.decide(
            hasConsent: hasConsent, latest: latest[memberID], me: me, sentAddress: sentAddresses[memberID],
            parentName: parentName, now: now
        )
    }

    func notice(for memberID: UUID) -> String? { notices[memberID] }

    /// The next ask needs an address, and none was typed on this device yet.
    func needsTypedEmail(_ memberID: UUID) -> Bool {
        typedEmailNeeded.contains(memberID) && resendAddress(for: memberID) == nil
    }

    /// The address this device typed for the kid's waiting email, which Send again sends to again. Asking again after
    /// a request ended takes a fresh one, so a mistyped address isn't reused.
    func resendAddress(for memberID: UUID) -> String? {
        guard typedEmailNeeded.contains(memberID), let request = latest[memberID],
              request.emailSource == .typed, request.status == .pending else { return nil }
        return sentAddresses[memberID]
    }

    /// Keeps the newest of each kid's requests, from rows in any order. A notice belongs to the request it was about,
    /// so it goes once that request moves on (agreed, ended, or replaced by a new one).
    mutating func replace(with requests: [ParentalConsentRequest]) {
        let loaded: [UUID: ParentalConsentRequest] = requests.reduce(into: [:]) { newest, request in
            if newest[request.memberID].map({ $0.createdAt < request.createdAt }) ?? true {
                newest[request.memberID] = request
            }
        }
        for (memberID, request) in loaded where latest[memberID].map({ ($0.id, $0.status) != (request.id, request.status) }) ?? true {
            notices[memberID] = nil
        }
        latest = loaded
    }

    mutating func record(_ answer: ParentalConsentAnswer, for member: Member, me: UUID, now: Date) {
        notices[member.id] = nil
        switch answer {
        case .sent(let requestID, let email, let source):
            // A typed address goes with Send again, since the account still has none.
            if source == .typed { typedEmailNeeded.insert(member.id) } else { typedEmailNeeded.remove(member.id) }
            sentAddresses[member.id] = email
            // Shows Check your email at once; the next load brings the server's row.
            latest[member.id] = ParentalConsentRequest(
                id: requestID, householdID: member.householdID, memberID: member.id, requestedBy: me,
                status: .pending, emailSource: source, expiresAt: now.addingTimeInterval(Self.linkLife), createdAt: now
            )
        case .alreadyConsented:
            typedEmailNeeded.remove(member.id)
        case .noEmail:
            typedEmailNeeded.insert(member.id)
        }
    }

    mutating func record(_ error: any Error, for memberID: UUID) {
        notices[memberID] = ((error as? ParentalConsentError) ?? .tryAgain).message
    }

    mutating func forget(_ memberID: UUID) {
        latest[memberID] = nil
        sentAddresses[memberID] = nil
        typedEmailNeeded.remove(memberID)
        notices[memberID] = nil
    }
}

/// The same check the server makes on a typed address, so an obvious typo is caught before sending.
enum ConsentEmail {
    static func isValid(_ typed: String) -> Bool {
        let email = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.count <= 254 && email.wholeMatch(of: /[^@\s<>",;]+@[^@\s<>",;]+\.[^@\s<>",;]+/) != nil
    }
}
