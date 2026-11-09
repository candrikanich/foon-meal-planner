import Foundation
import Supabase
import Testing
@testable import Foon

/// Every status and body `parental-consent` answers the app with (#275 contract, section 1).
struct ParentalConsentAnswerTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test func sentCarriesTheRequestAndTheAddress() throws {
        let id = UUID()
        let answer = try ParentalConsentAnswer.decode(status: 200, body: body("""
            {"result":"sent","requestId":"\(id.uuidString.lowercased())","email":"ann@example.com","emailSource":"typed"}
            """))
        #expect(answer == .sent(requestID: id, email: "ann@example.com", source: .typed))
    }

    @Test func alreadyConsentedAndNoEmail() throws {
        #expect(try ParentalConsentAnswer.decode(status: 200, body: body(#"{"result":"already_consented"}"#))
                == .alreadyConsented)
        #expect(try ParentalConsentAnswer.decode(status: 200, body: body(#"{"result":"no_email"}"#)) == .noEmail)
    }

    @Test func anAnswerThisVersionDoesntKnowIsATryAgain() {
        #expect(throws: ParentalConsentError.tryAgain) {
            try ParentalConsentAnswer.decode(status: 200, body: body(#"{"result":"something_new"}"#))
        }
        #expect(throws: ParentalConsentError.tryAgain) {
            try ParentalConsentAnswer.decode(status: 200, body: body(#"{"result":"sent"}"#))
        }
    }

    @Test(arguments: [
        (400, #"{"error":"bad_request"}"#, ParentalConsentError.badRequest),
        (400, #"{"error":"bad_email"}"#, .badEmail),
        (401, #"{"error":"not_signed_in"}"#, .notSignedIn),
        (403, #"{"error":"not_a_parent"}"#, .notAParent),
        (409, #"{"error":"not_eligible"}"#, .notEligible),
        (429, #"{"error":"rate_limited","message":"Try again in a little while."}"#, .rateLimited),
        (502, #"{"error":"send_failed"}"#, .sendFailed),
        (503, #"{"error":"email_off"}"#, .emailOff),
        (500, #"{"error":"try_again"}"#, .tryAgain),
        (504, "<html>gateway</html>", .tryAgain)
    ])
    func everyErrorStatusThrowsItsOwnError(status: Int, json: String, expected: ParentalConsentError) {
        #expect(throws: expected) {
            try ParentalConsentAnswer.decode(status: status, body: body(json))
        }
    }

    @Test func theAskSendsMemberIdAndAnEmailOnlyWhenTyped() throws {
        let id = UUID()
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConsentAsk(memberID: id, email: nil)))
        #expect(plain as? [String: String] == ["memberId": id.uuidString.lowercased()])
        let typed = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ConsentAsk(memberID: id, email: "ann@example.com"))
        )
        #expect(typed as? [String: String] == ["memberId": id.uuidString.lowercased(), "email": "ann@example.com"])
    }

    @Test func everyRefusalHasAMessage() {
        let all: [ParentalConsentError] = [
            .badRequest, .badEmail, .notSignedIn, .notAParent, .notEligible, .rateLimited, .sendFailed, .emailOff, .tryAgain
        ]
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }
}

/// The rows the app reads, with the explicit columns the grant allows.
struct ParentalConsentRequestDecodingTests {
    @Test func decodesARowAsPostgRESTSendsIt() throws {
        let json = """
            [{"id":"6f1c2a52-8f0e-4c55-9f3e-0d6c1b2a3e4f","household_id":"00000000-0000-0000-0000-0000000000a0",
              "member_id":"6f1c2a52-8f0e-4c55-9f3e-0d6c1b2a3e40","requested_by":"00000000-0000-0000-0000-0000000000f1",
              "status":"consented","email_source":"account","text_version":"parental-invite-v3",
              "token_sent_at":"2026-11-08T14:00:00.123456+00:00","expires_at":"2026-11-15T14:00:00.123456+00:00",
              "decided_at":"2026-11-08T15:00:00+00:00","confirmed_at":null,"ended_at":null,
              "created_at":"2026-11-08T13:59:59+00:00"}]
            """
        let rows = try PostgrestClient.Configuration.jsonDecoder.decode([ParentalConsentRequest].self, from: Data(json.utf8))
        let row = try #require(rows.first)
        #expect(row.status == .consented)
        #expect(row.emailSource == .account)
        #expect(row.requestedBy == .previewUser)
        #expect(row.expiresAt != nil)
    }

    @Test func aStatusThisVersionDoesntKnowReadsAsEnded() throws {
        let json = """
            {"id":"6f1c2a52-8f0e-4c55-9f3e-0d6c1b2a3e4f","household_id":"00000000-0000-0000-0000-0000000000a0",
             "member_id":"6f1c2a52-8f0e-4c55-9f3e-0d6c1b2a3e40","requested_by":"00000000-0000-0000-0000-0000000000f1",
             "status":"on_hold","email_source":null,"expires_at":null,"created_at":"2026-11-08T13:59:59+00:00"}
            """
        let row = try PostgrestClient.Configuration.jsonDecoder.decode(ParentalConsentRequest.self, from: Data(json.utf8))
        #expect(row.status == .cancelled)
    }

    @Test func selectsOnlyTheGrantedColumns() {
        let columns = Set(ParentalConsentRequest.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(columns == [
            "id", "household_id", "member_id", "requested_by", "status", "email_source", "text_version", "token_sent_at",
            "expires_at", "decided_at", "confirmed_at", "ended_at", "created_at"
        ])
    }
}

/// "How C should decide what to show" in #275's contract, one row at a time.
struct ParentalConsentStepTests {
    private let me = UUID()
    private let ben = UUID()
    private let kid = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(
        _ status: ParentalConsentRequest.Status, by parent: UUID? = nil, expiresIn: TimeInterval = 3600,
        source: ParentalConsentRequest.EmailSource? = .account
    ) -> ParentalConsentRequest {
        ParentalConsentRequest(
            id: UUID(), householdID: UUID(), memberID: kid, requestedBy: parent ?? me, status: status,
            emailSource: source, expiresAt: now.addingTimeInterval(expiresIn), createdAt: now
        )
    }

    private func step(
        consent: Bool = false, _ latest: ParentalConsentRequest?, sentAddress: String? = nil
    ) -> ParentalConsentStep {
        ParentalConsentStep.decide(
            hasConsent: consent, latest: latest, me: me, sentAddress: sentAddress,
            parentName: { [ben] id in id == ben ? "Ben" : nil }, now: now
        )
    }

    @Test func anActiveConsentShowsInviteWhateverTheRequestSays() {
        #expect(step(consent: true, request(.pending)) == .invite)
        #expect(step(consent: true, nil) == .invite)
    }

    @Test func noRequestIsEmailMe() {
        #expect(step(nil) == .emailMe)
    }

    @Test func pendingIsCheckYourEmail() {
        #expect(step(request(.pending)) == .checkEmail(sentTo: .accountEmail, askedBy: .me))
        #expect(step(request(.pending, source: .typed)) == .checkEmail(sentTo: .typedEmail, askedBy: .me))
        #expect(step(request(.pending), sentAddress: "ann@example.com")
                == .checkEmail(sentTo: .address("ann@example.com"), askedBy: .me))
        #expect(step(request(.pending), sentAddress: "abc@privaterelay.appleid.com")
                == .checkEmail(sentTo: .hideMyEmail, askedBy: .me))
    }

    @Test func consentedIsAlmostDone() {
        #expect(step(request(.consented)) == .almostDone(askedBy: .me))
        #expect(step(request(.consented)).button == nil, "Send again would be refused: they finish from the email")
    }

    @Test func aLapsedLinkIsSendANewEmailEvenBeforeTheDailyJob() {
        #expect(step(request(.pending, expiresIn: -1)) == .sendNewEmail)
        #expect(step(request(.consented, expiresIn: -1)) == .sendNewEmail)
    }

    @Test func refusedIsAskAgain() {
        #expect(step(request(.refused)) == .refused(askedBy: .me))
        #expect(step(request(.refused)).button == "Ask again")
    }

    @Test(arguments: [ParentalConsentRequest.Status.expired, .cancelled, .confirmed])
    func endedOrWithdrawnIsSendANewEmail(status: ParentalConsentRequest.Status) {
        #expect(step(request(status)) == .sendNewEmail)
    }

    @Test func anotherParentsRequestNeverShowsTheirAddress() {
        #expect(step(request(.pending, by: ben), sentAddress: "ann@example.com")
                == .checkEmail(sentTo: .accountEmail, askedBy: .otherParent(firstName: "Ben")))
        #expect(step(request(.refused, by: UUID())) == .refused(askedBy: .otherParent(firstName: nil)))
    }

    @Test func aFirstSendStillInFlightIsCheckYourEmail() {
        let inFlight = ParentalConsentRequest(
            id: UUID(), householdID: UUID(), memberID: kid, requestedBy: me, status: .pending, emailSource: nil,
            expiresAt: nil, createdAt: now
        )
        #expect(step(inFlight) == .checkEmail(sentTo: .accountEmail, askedBy: .me))
    }
}

struct ParentalConsentBookTests {
    private let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)

    private func request(_ status: ParentalConsentRequest.Status, created: Date) -> ParentalConsentRequest {
        ParentalConsentRequest(
            id: UUID(), householdID: kid.householdID, memberID: kid.id, requestedBy: UUID(), status: status,
            emailSource: .account, expiresAt: created.addingTimeInterval(86_400), createdAt: created
        )
    }

    @Test func keepsTheNewestRequestForEachKid() {
        var book = ParentalConsentBook()
        let older = request(.refused, created: .now.addingTimeInterval(-600))
        let newer = request(.pending, created: .now)
        book.replace(with: [newer, older])
        #expect(book.latest[kid.id] == newer)
        book.replace(with: [older, newer])
        #expect(book.latest[kid.id] == newer)
    }

    @Test func aNoticeGoesOnceItsRequestMovesOn() {
        var book = ParentalConsentBook()
        let pending = request(.pending, created: .now)
        book.replace(with: [pending])
        book.record(ParentalConsentError.rateLimited, for: kid.id)
        // The reload after a refusal finds the same request where it was: the notice stays.
        book.replace(with: [pending])
        #expect(book.notice(for: kid.id) == ParentalConsentError.rateLimited.message)
        // The parent agreed in the email: it was about the old state, so it goes.
        let agreed = ParentalConsentRequest(
            id: pending.id, householdID: pending.householdID, memberID: kid.id, requestedBy: pending.requestedBy,
            status: .confirmed, emailSource: .account, expiresAt: pending.expiresAt, createdAt: pending.createdAt
        )
        book.replace(with: [agreed])
        #expect(book.notice(for: kid.id) == nil)
    }

    @Test func aNoticeGoesWhenANewRequestReplacesTheOld() {
        var book = ParentalConsentBook()
        book.replace(with: [request(.refused, created: .now.addingTimeInterval(-600))])
        book.record(ParentalConsentError.sendFailed, for: kid.id)
        book.replace(with: [request(.pending, created: .now)])
        #expect(book.notice(for: kid.id) == nil)
    }

    @Test func forgettingAKidClearsEverything() {
        var book = ParentalConsentBook()
        book.record(.noEmail, for: kid, me: UUID(), now: .now)
        book.record(ParentalConsentError.rateLimited, for: kid.id)
        book.forget(kid.id)
        #expect(book == ParentalConsentBook())
    }
}

struct ConsentEmailTests {
    @Test(arguments: ["ann@example.com", " ann@example.co.uk ", "a+b@x.io"])
    func acceptsAddresses(email: String) {
        #expect(ConsentEmail.isValid(email))
    }

    @Test(arguments: ["", "ann", "ann@example", "@example.com", "ann@@example.com", "ann smith@example.com",
                      "ann@example.com,bob@example.com", String(repeating: "a", count: 250) + "@x.io"])
    func refusesWhatTheServerWould(email: String) {
        #expect(!ConsentEmail.isValid(email))
    }
}
