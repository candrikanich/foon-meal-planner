import Foundation
import Testing
@testable import Foon

struct InviteEmailRequestTests {
    @Test func goesToTheAccountEmailInviteDoor() {
        #expect(InviteEmailRequest.function == "account-email")
        #expect(InviteEmailRequest.query == [URLQueryItem(name: "invite", value: "1")])
    }

    @Test func carriesTheMemberTheCodeAndTheTrimmedAddressOnly() throws {
        let memberID = UUID()
        let request = InviteEmailRequest(memberID: memberID, code: "THESM-7KQ4-M9XP", email: "  sam@example.com \n")
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )
        #expect(json == ["memberId": memberID.uuidString, "code": "THESM-7KQ4-M9XP", "email": "sam@example.com"])
    }
}

struct InviteEmailErrorTests {
    private func error(_ status: Int, _ code: String) -> InviteEmailError {
        InviteEmailError(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8))
    }

    @Test func readsEachOfTheFunctionsAnswers() {
        #expect(error(400, "bad_email") == .badEmail)
        #expect(error(400, "bad_request") == .tryAgain)
        #expect(error(401, "not_signed_in") == .notSignedIn)
        #expect(error(403, "not_a_parent") == .notAParent)
        #expect(error(409, "kid") == .kid)
        #expect(error(409, "not_invitable") == .alreadyJoined)
        #expect(error(409, "wrong_code") == .inviteChanged)
        #expect(error(429, "rate_limited") == .rateLimited)
        #expect(error(502, "send_failed") == .sendFailed)
        #expect(error(503, "email_off") == .emailOff)
        #expect(InviteEmailError(status: 500, body: Data("oops".utf8)) == .tryAgain)
    }

    @Test func emailOffSaysFoonDoesntSendEmailYet() {
        #expect(InviteEmailError.emailOff.message == "Foon doesn't send email yet.")
    }
}

@MainActor
struct InviteEmailModelTests {
    private let gran = Member.fixture(firstName: "Gran")

    private func model(
        _ result: @escaping @Sendable () throws -> Void = {}
    ) -> (InviteEmailModel, LockedBox<[InviteEmailRequest]>) {
        let sent = LockedBox<[InviteEmailRequest]>([])
        let model = InviteEmailModel(member: gran, code: "THESM-7KQ4-M9XP") { request in
            sent.set(sent.value + [request])
            try result()
        }
        return (model, sent)
    }

    @Test func nothingToSendUntilSomethingIsTyped() {
        let (model, _) = model()
        #expect(!model.canSend)
        model.address = "   "
        #expect(!model.canSend)
        model.address = "gran@example.com"
        #expect(model.canSend)
    }

    @Test(arguments: ["gran", "gran@example", "gran@@example.com", "gran smith@example.com", "<gran@example.com>"])
    func aBadAddressIsCaughtBeforeSending(typed: String) async {
        let (model, sent) = model()
        model.address = typed
        await model.send()
        #expect(model.errorMessage == InviteEmailError.badEmail.message)
        #expect(sent.value.isEmpty)
    }

    @Test func sendsTheMembersCodeToTheTrimmedAddressThenForgetsIt() async {
        let (model, sent) = model()
        model.address = " gran@example.com "
        await model.send()
        #expect(sent.value == [
            InviteEmailRequest(memberID: gran.id, code: "THESM-7KQ4-M9XP", email: "gran@example.com")
        ])
        #expect(model.phase == .sent)
        #expect(model.address.isEmpty, "the address isn't kept once the email is out")
        #expect(!model.canSend, "sent once")
    }

    @Test func aRefusalShowsItsMessageAndCanBeTriedAgain() async {
        let (model, sent) = model { throw InviteEmailError.emailOff }
        model.address = "gran@example.com"
        await model.send()
        #expect(model.errorMessage == "Foon doesn't send email yet.")
        #expect(model.canSend)
        await model.send()
        #expect(sent.value.count == 2)
    }

    @Test func anyOtherFailureSaysTryAgain() async {
        let (model, _) = model { throw URLError(.notConnectedToInternet) }
        model.address = "gran@example.com"
        await model.send()
        #expect(model.errorMessage == InviteEmailError.tryAgain.message)
    }
}
