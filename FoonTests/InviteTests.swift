import Foundation
import Synchronization
import Testing
@testable import Foon

struct InviteCodeTests {
    @Test(arguments: [("ANDRI-7KQ4-M9XP", "ANDRI7KQ4M9XP"), (" andri 7kq4 m9xp ", "ANDRI7KQ4M9XP"), ("7kq4m9xp", "7KQ4M9XP")])
    func normalizesWhatPeopleType(typed: String, expected: String) {
        #expect(InviteCode.normalized(typed) == expected)
    }

    @Test func needsAtLeastEightCharacters() {
        #expect(!InviteCode.isComplete("7KQ4-M9X"))
        #expect(InviteCode.isComplete("7KQ4M9XP"))
    }

    @Test func roundTripsThroughTheUniversalLink() throws {
        let url = InviteCode.link(for: "ANDRI-7KQ4-M9XP")
        #expect(url.absoluteString == "https://www.getfoon.com/invite?code=ANDRI-7KQ4-M9XP")
        #expect(InviteCode.code(from: url) == "ANDRI-7KQ4-M9XP")
    }

    @Test(arguments: ["foon://invite/ANDRI-7KQ4-M9XP", "https://getfoon.com/invite?code=ANDRI-7KQ4-M9XP"])
    func stillAcceptsOlderAndApexLinks(link: String) throws {
        #expect(InviteCode.code(from: try #require(URL(string: link))) == "ANDRI-7KQ4-M9XP")
    }

    @Test func testsRunAsFoonNotFoonQA() {
        #expect(InviteCode.Links.current == .production)
    }

    /// Foon QA (the Staging build) has its own path, so its invites open Foon QA beside the family's Foon.
    @Test func foonQALinksUseTheQAPath() throws {
        let url = InviteCode.link(for: "ANDRI-7KQ4-M9XP", links: .qa)
        #expect(url.absoluteString == "https://www.getfoon.com/qa/invite?code=ANDRI-7KQ4-M9XP")
        #expect(InviteCode.code(from: url, links: .qa) == "ANDRI-7KQ4-M9XP")
        #expect(InviteCode.code(from: url, links: .production) == "ANDRI-7KQ4-M9XP", "the server decides, not the path")
        let message = InviteCode.shareMessage(householdName: "The Andrikanichs", firstName: "Owen", code: "X", links: .qa)
        #expect(message.contains("https://www.getfoon.com/qa/invite?code=X"))
    }

    @Test func eachAppTakesOnlyItsOwnScheme() throws {
        let qa = try #require(URL(string: "foonqa://invite/ANDRI-7KQ4-M9XP"))
        let foon = try #require(URL(string: "foon://invite/ANDRI-7KQ4-M9XP"))
        #expect(InviteCode.code(from: qa, links: .qa) == "ANDRI-7KQ4-M9XP")
        #expect(InviteCode.code(from: foon, links: .qa) == nil)
        #expect(InviteCode.code(from: qa, links: .production) == nil)
    }

    @Test(arguments: [
        "foon://recipe/123", "https://example.com/invite?code=ABC", "foon://invite/",
        "https://www.getfoon.com/invite", "https://www.getfoon.com/invite?code=",
        "https://www.getfoon.com/privacy?code=ABC", "https://www.getfoon.com/qa?code=ABC",
        "http://www.getfoon.com/invite?code=ABC",
    ])
    func ignoresOtherLinks(link: String) throws {
        #expect(InviteCode.code(from: try #require(URL(string: link))) == nil)
    }

    @Test func shareMessageCarriesTheLinkAndTheCode() {
        let message = InviteCode.shareMessage(householdName: "The Andrikanichs", firstName: "Owen", code: "ANDRI-7KQ4-M9XP")
        #expect(message.contains("The Andrikanichs"))
        #expect(message.contains("https://www.getfoon.com/invite?code=ANDRI-7KQ4-M9XP"))
        #expect(message.contains("ANDRI-7KQ4-M9XP"))
    }
}

@MainActor
struct HouseholdStoreInviteTests {
    private let me = UUID()
    private var owned: Household { Household(id: Household.sample.id, name: "The Smiths", emoji: nil, owner: me) }

    @Test func parentsInviteUnclaimedProfilesOnly() async {
        let owner = Member.fixture(firstName: "Ann", guardian: true, userID: me)
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let claimed = Member.fixture(firstName: "Ben", userID: UUID())
        let gone = Member.fixture(firstName: "Rita", status: .removed)
        let store = HouseholdStore(userID: me, client: .preview(household: owned, members: [owner, kid, claimed, gone]))
        await store.load()
        #expect(store.canInvite(kid))
        #expect(!store.canInvite(claimed))
        #expect(!store.canInvite(gone))
        #expect(!store.canInvite(owner))
    }

    @Test func nonParentsCannotInvite() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let grandma = Member.fixture(firstName: "Grace", role: .planner, userID: me)
        let store = HouseholdStore(userID: me, client: .preview(household: .sample, members: [grandma, kid]))
        await store.load()
        #expect(!store.canInvite(kid))
    }

    @Test func invitingReturnsTheCodeAndMarksTheProfile() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.createInvite = { _ in "THESM-7KQ4-M9XP" }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(await store.invite(kid) == "THESM-7KQ4-M9XP")
        #expect(store.invitedMemberIDs.contains(kid.id))
    }

    @Test func loadsWhichProfilesHaveOpenInvites() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.invitedMemberIDs = { _ in [kid.id] }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.invitedMemberIDs == [kid.id])
    }

    @Test func claimingAnInviteLoadsTheHousehold() async {
        let joined = Mutex(false)
        var client = HouseholdClient.preview(household: nil, members: [])
        client.myHousehold = { joined.withLock { $0 } ? .sample : nil }
        client.redeemInvite = { code, ageBand in
            #expect(code == "THESM7KQ4M9XP")
            #expect(ageBand == .adult)
            joined.withLock { $0 = true }
            return .claimed
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.phase == .needsHousehold)
        await store.redeem(" thesm 7kq4 m9xp ", ageBand: .adult)
        #expect(store.phase == .ready(.sample))
    }

    @Test(arguments: [RedeemResult.invalid, .expired, .used, .hasHousehold, .rateLimited])
    func eachFailedRedeemExplainsItself(result: RedeemResult) async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.redeemInvite = { _, _ in result }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        await store.redeem("THESM-7KQ4-M9XP", ageBand: .unknown)
        #expect(store.phase == .needsHousehold)
        #expect(store.errorMessage != nil)
    }

    @Test func anIncompleteCodeIsNotSent() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.redeemInvite = { _, _ in
            Issue.record("should not be called")
            return .invalid
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.redeem("7KQ4", ageBand: .unknown)
        #expect(store.errorMessage != nil)
    }
}

/// A kid's invite waits for a parent's consent by email (COPPA email plus, #275).
@MainActor
struct ParentalConsentTests {
    private let me = UUID()
    private var owned: Household { Household(id: Household.sample.id, name: "The Smiths", emoji: nil, owner: me) }

    private func request(
        _ status: ParentalConsentRequest.Status, for kid: Member, by parent: UUID? = nil
    ) -> ParentalConsentRequest {
        ParentalConsentRequest(
            id: UUID(), householdID: Household.sample.id, memberID: kid.id, requestedBy: parent ?? me, status: status,
            emailSource: .account, expiresAt: .now.addingTimeInterval(86_400), createdAt: .now
        )
    }

    private func loadedStore(_ client: HouseholdClient) async -> HouseholdStore {
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        await store.loadConsentRequests()
        return store
    }

    @Test func aKidNeedsAParentsConsentBeforeAnInvite() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let adult = Member.fixture(firstName: "Ben")
        let store = await loadedStore(.preview(household: owned, members: [kid, adult]))
        #expect(store.needsParentalConsent(kid))
        #expect(!store.needsParentalConsent(adult))
        #expect(store.consentStep(for: kid) == .emailMe)
    }

    @Test func emailMeShowsCheckYourEmailWithTheAddress() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let asked = Mutex<[UUID]>([])
        let emails = Mutex<[String?]>([])
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { memberID, email in
            asked.withLock { $0.append(memberID) }
            emails.withLock { $0.append(email) }
            return .sent(requestID: UUID(), email: "ann@example.com", source: .account)
        }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(asked.withLock { $0 } == [kid.id])
        #expect(emails.withLock { $0 } == [nil], "the account's own address is used")
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .address("ann@example.com"), askedBy: .me))
        #expect(store.needsParentalConsent(kid), "consent is active only once the parent agrees in the email")
    }

    @Test func aHideMyEmailAddressIsDescribedNotShown() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, _ in
            .sent(requestID: UUID(), email: "x7q2p9@PrivateRelay.AppleID.com", source: .account)
        }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .hideMyEmail, askedBy: .me))
        let shown = ConsentEmailAddress.hideMyEmail.description
        #expect(shown.contains("Hide My Email"))
        #expect(!shown.contains("@"))
        #expect(ConsentEmailAddress(sentTo: "ann@example.com").description == "ann@example.com")
    }

    @Test func sendAgainAsksTheServerAgainForTheSameKid() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let asks = Mutex(0)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        let pending = request(.pending, for: kid)
        client.parentalConsentRequests = { _ in [pending] }
        client.requestParentalConsent = { _, _ in
            asks.withLock { $0 += 1 }
            return .sent(requestID: UUID(), email: "ann@example.com", source: .account)
        }
        let store = await loadedStore(client)
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .accountEmail, askedBy: .me),
                "after a reload the address isn't known, so it says which one")
        #expect(store.consentStep(for: kid).button == "Send again")
        await store.askForConsent(kid)
        #expect(asks.withLock { $0 } == 1)
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .address("ann@example.com"), askedBy: .me))
    }

    @Test func noEmailAsksForOneAndSendAgainReusesIt() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let emails = Mutex<[String?]>([])
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, email in
            emails.withLock { $0.append(email) }
            guard let email else { return .noEmail }
            return .sent(requestID: UUID(), email: email, source: .typed)
        }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentRequests.needsTypedEmail(kid.id))
        #expect(store.consentStep(for: kid) == .emailMe)

        await store.askForConsent(kid, email: "ann@example")
        #expect(emails.withLock { $0.count } == 1, "a malformed address isn't sent")
        #expect(store.consentRequests.notice(for: kid.id) == ParentalConsentError.badEmail.message)

        await store.askForConsent(kid, email: "ann@example.com")
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .address("ann@example.com"), askedBy: .me))
        #expect(store.consentRequests.notice(for: kid.id) == nil)
        #expect(!store.consentRequests.needsTypedEmail(kid.id), "the typed address is known for Send again")

        await store.askForConsent(kid)
        #expect(emails.withLock { $0 } == [nil, "ann@example.com", "ann@example.com"])
    }

    @Test func aRateLimitSaysTryAgainInALittleWhile() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, _ in throw ParentalConsentError.rateLimited }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentRequests.notice(for: kid.id) == String(localized: "Try again in a little while."))
        #expect(store.consentStep(for: kid) == .emailMe)
        #expect(store.errorMessage == nil, "a calm note in the section, not an error")
    }

    @Test(arguments: [ParentalConsentError.emailOff, .sendFailed, .tryAgain, .notEligible])
    func otherRefusalsLeaveACalmNote(error: ParentalConsentError) async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, _ in throw error }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentRequests.notice(for: kid.id) == error.message)
    }

    @Test func aTryAgainReloadsAndShowsTheRealState() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let asked = Mutex(false)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        let consented = request(.consented, for: kid)
        client.parentalConsentRequests = { _ in asked.withLock { $0 } ? [consented] : [] }
        client.requestParentalConsent = { _, _ in
            asked.withLock { $0 = true }
            throw ParentalConsentError.tryAgain
        }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentStep(for: kid) == .almostDone(askedBy: .me))
        #expect(store.consentRequests.notice(for: kid.id) == ParentalConsentError.tryAgain.message)
    }

    @Test func aDroppedConnectionLeavesACalmNoteToo() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(store.consentRequests.notice(for: kid.id) == ParentalConsentError.tryAgain.message)
    }

    @Test func alreadyConsentedShowsInvite() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.requestParentalConsent = { _, _ in .alreadyConsented }
        let store = await loadedStore(client)
        await store.askForConsent(kid)
        #expect(!store.needsParentalConsent(kid))
        #expect(store.consentStep(for: kid) == .invite)
    }

    @Test func agreeingInTheEmailShowsInviteOnTheNextLoad() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let agreed = Mutex(false)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.parentalConsentMemberIDs = { _ in agreed.withLock { $0 } ? [kid.id] : [] }
        let pending = request(.pending, for: kid)
        let confirmed = request(.confirmed, for: kid)
        client.parentalConsentRequests = { _ in [agreed.withLock { $0 } ? confirmed : pending] }
        let store = await loadedStore(client)
        #expect(store.consentStep(for: kid) == .checkEmail(sentTo: .accountEmail, askedBy: .me))
        agreed.withLock { $0 = true }
        await store.loadConsentRequests()
        #expect(store.consentStep(for: kid) == .invite)
        #expect(await store.invite(kid) == "THESM-7KQ4-M9XP", "the invite code is still made in the app")
    }

    @Test func anotherParentsRequestIsShownAsTheirs() async {
        let ben = Member.fixture(firstName: "Ben", guardian: true, userID: UUID())
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        var client = HouseholdClient.preview(household: owned, members: [ben, kid])
        let theirs = request(.refused, for: kid, by: ben.userID)
        client.parentalConsentRequests = { _ in [theirs] }
        let store = await loadedStore(client)
        #expect(store.consentStep(for: kid) == .refused(askedBy: .otherParent(firstName: "Ben")))
    }

    @Test func withdrawingConsentUnlinksTheKidLocally() async {
        let kid = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: UUID())
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.parentalConsentMemberIDs = { _ in [kid.id] }
        client.revokeParentalConsent = { _ in }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.canWithdrawConsent(kid))
        #expect(await store.withdrawConsent(kid))
        #expect(store.needsParentalConsent(kid))
        #expect(store.members.first?.userID == nil)
    }

    @Test func aConsentThatFailedToLoadIsFoundWhenTheEditorOpens() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let loads = Mutex(0)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.parentalConsentMemberIDs = { _ in
            loads.withLock { $0 += 1 }
            if loads.withLock({ $0 }) == 1 { throw URLError(.timedOut) }
            return [kid.id]
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.consentStep(for: kid) == .emailMe)
        await store.loadConsentRequests()
        #expect(store.consentStep(for: kid) == .invite)
    }

    @Test func aParentWhoIsntOneReadsNoRequests() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let someoneElses = Household(id: Household.sample.id, name: "The Smiths", emoji: nil, owner: UUID())
        var client = HouseholdClient.preview(household: someoneElses, members: [kid])
        client.parentalConsentRequests = { _ in
            Issue.record("only parents ask for the requests")
            return []
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        await store.loadConsentRequests()
    }

    @Test(arguments: [RedeemResult.needsConsent, .ageMismatch])
    func newRedeemResultsExplainThemselves(result: RedeemResult) {
        #expect(result.message != nil)
    }
}
