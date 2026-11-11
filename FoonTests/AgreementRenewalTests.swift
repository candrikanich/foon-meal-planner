import Foundation
import Supabase
import Testing
@testable import Foon

/// A held kid's device never reads a failed check as "not held" (#277): starting or joining a household then would end
/// the hold as account_gone.
@MainActor
struct AccessHoldFailureTests {
    private struct Flaky: Error {}

    @Test func aFailedCheckBeforeAnythingLoadedOffersTryAgain() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.accessHold = { throw URLError(.notConnectedToInternet) }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(store.phase == .failed, "not Create household")
    }

    @Test func aFailedCheckWhileHeldStaysHeld() async {
        let offline = LockedBox(false)
        var client = HouseholdClient.preview(household: nil, members: [])
        client.accessHold = {
            if offline.value { throw URLError(.notConnectedToInternet) }
            return .preview
        }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(store.phase == .held(.preview))
        offline.set(true)
        await store.load()
        #expect(store.phase == .held(.preview), "Check again offline keeps them waiting")
        await store.refreshQuietly()
        #expect(store.phase == .held(.preview))
    }

    @Test func aServerWithoutTheFunctionHoldsNobody() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.accessHold = { throw PostgrestError(code: "PGRST202", message: "Could not find the function") }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(store.phase == .needsHousehold)
    }
}

/// A held kid's consent section once the renewal emails are out (#277): every parent already has a waiting request.
@MainActor
struct ConsentRenewalStepTests {
    private let owen = Member.sampleFamily[3]
    private let ben = UUID()

    private func request(_ status: ParentalConsentRequest.Status, by parent: UUID = .previewUser,
                         created: Date = .now.addingTimeInterval(-600)) -> ParentalConsentRequest {
        ParentalConsentRequest(id: UUID(), householdID: Household.sample.id, memberID: owen.id, requestedBy: parent,
                               status: status, emailSource: .account, expiresAt: .now.addingTimeInterval(86_400),
                               createdAt: created)
    }

    private func store(requests: [ParentalConsentRequest]) async -> HouseholdStore {
        let held = owen.id
        var client = HouseholdClient.preview()
        client.parentalConsentMemberIDs = { _ in [held] }
        client.agreements = { _ in .previewHeld }
        client.parentalConsentRequests = { _ in requests }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadConsentRequests()
        return store
    }

    @Test func aWaitingRenewalEmailSaysSoInRenewalWords() async throws {
        let store = await store(requests: [request(.pending)])
        let step = store.consentStep(for: owen)
        #expect(step == .checkEmail(sentTo: .accountEmail, askedBy: .me))
        let line = try #require(step.renewalLine(firstName: "Owen"))
        #expect(line.contains("We sent the form"))
        #expect(!line.contains("invite"), "a held kid isn't invited again")
    }

    @Test func theOldConfirmedRequestIsAFirstAskOfTheForm() async {
        let store = await store(requests: [request(.confirmed, created: .now.addingTimeInterval(-90 * 86_400))])
        let step = store.consentStep(for: owen)
        #expect(step == .emailMe)
        #expect(step.button(renewing: true) == "Email me the form")
        #expect(step.renewalLine(firstName: "Owen") == nil, "the hold's lines say it all")
    }

    @Test func withoutAHoldAConfirmedRequestStillOffersANewEmail() {
        let step = ParentalConsentStep.decide(hasConsent: false, latest: request(.confirmed), me: .previewUser,
                                              sentAddress: nil, parentName: { _ in nil }, now: .now)
        #expect(step == .sendNewEmail)
    }

    @Test(arguments: [true, false])
    func onATieMyOwnRenewalEmailWins(mineFirst: Bool) {
        let created = Date.now.addingTimeInterval(-60)
        let mine = request(.pending, created: created)
        let bens = request(.pending, by: ben, created: created)
        var book = ParentalConsentBook()
        book.replace(with: mineFirst ? [mine, bens] : [bens, mine], me: .previewUser)
        #expect(book.latest[owen.id]?.id == mine.id)
    }

    @Test func aNewerRequestStillBeatsMineOnATie() {
        let mine = request(.pending, created: .now.addingTimeInterval(-120))
        let bens = request(.pending, by: ben, created: .now.addingTimeInterval(-60))
        var book = ParentalConsentBook()
        book.replace(with: [mine, bens], me: .previewUser)
        #expect(book.latest[owen.id]?.id == bens.id)
    }

    @Test func anotherParentsWaitingEmailNeverSaysInvite() throws {
        let step = ParentalConsentStep.checkEmail(sentTo: .accountEmail, askedBy: .otherParent(firstName: "Ben"))
        let line = try #require(step.renewalLine(firstName: "Owen"))
        #expect(line == "Foon emailed Ben the form. Once a parent agrees, Owen can use Foon.")
    }
}

/// The Terms context belongs to the agreement it was logged with.
@MainActor
struct TermsContextTests {
    @Test func aLaterGateAfterJoiningIsntLoggedAsAJoin() async {
        var client = HouseholdClient.preview()
        client.agreements = { _ in .previewTermsNew }
        client.redeemInvite = { _, _ in .claimed }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.redeem("THESM-7KQ4-M9XP", ageBand: .adult)
        #expect(store.termsGate()?.context == .join)
        await store.recordTermsAccepted()
        #expect(!store.joinedJustNow)
    }
}
