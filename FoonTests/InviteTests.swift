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

    @Test func roundTripsThroughTheAppLink() throws {
        let url = InviteCode.link(for: "ANDRI-7KQ4-M9XP")
        #expect(url.absoluteString == "foon://invite/ANDRI-7KQ4-M9XP")
        #expect(InviteCode.code(from: url) == "ANDRI-7KQ4-M9XP")
    }

    @Test(arguments: ["foon://recipe/123", "https://example.com/invite/ABC", "foon://invite/"])
    func ignoresOtherLinks(link: String) throws {
        #expect(InviteCode.code(from: try #require(URL(string: link))) == nil)
    }

    @Test func shareMessageCarriesTheLinkAndTheCode() {
        let message = InviteCode.shareMessage(householdName: "The Andrikanichs", firstName: "Owen", code: "ANDRI-7KQ4-M9XP")
        #expect(message.contains("The Andrikanichs"))
        #expect(message.contains("foon://invite/ANDRI-7KQ4-M9XP"))
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
        client.redeemInvite = { code in
            #expect(code == "THESM7KQ4M9XP")
            joined.withLock { $0 = true }
            return .claimed
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.phase == .needsHousehold)
        await store.redeem(" thesm 7kq4 m9xp ")
        #expect(store.phase == .ready(.sample))
    }

    @Test(arguments: [RedeemResult.invalid, .expired, .used, .hasHousehold, .rateLimited])
    func eachFailedRedeemExplainsItself(result: RedeemResult) async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.redeemInvite = { _ in result }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        await store.redeem("THESM-7KQ4-M9XP")
        #expect(store.phase == .needsHousehold)
        #expect(store.errorMessage != nil)
    }

    @Test func anIncompleteCodeIsNotSent() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.redeemInvite = { _ in
            Issue.record("should not be called")
            return .invalid
        }
        let store = HouseholdStore(userID: me, client: client)
        await store.redeem("7KQ4")
        #expect(store.errorMessage != nil)
    }
}

@MainActor
struct ParentalConsentTests {
    private let me = UUID()
    private var owned: Household { Household(id: Household.sample.id, name: "The Smiths", emoji: nil, owner: me) }

    @Test func aKidNeedsAParentsConsentBeforeAnInvite() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let adult = Member.fixture(firstName: "Ben")
        let store = HouseholdStore(userID: me, client: .preview(household: owned, members: [kid, adult]))
        await store.load()
        #expect(store.needsParentalConsent(kid))
        #expect(!store.needsParentalConsent(adult))
    }

    @Test func consentingRecordsItAndInvites() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let consented = Mutex<[UUID]>([])
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.recordParentalConsent = { _, memberID in consented.withLock { $0.append(memberID) } }
        client.createInvite = { _ in "THESM-7KQ4-M9XP" }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(await store.consentAndInvite(kid) == "THESM-7KQ4-M9XP")
        #expect(consented.withLock { $0 } == [kid.id])
        #expect(!store.needsParentalConsent(kid))
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

    @Test func anExistingConsentThatFailedToLoadStillLetsTheInviteGoOut() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let loads = Mutex(0)
        var client = HouseholdClient.preview(household: owned, members: [kid])
        client.parentalConsentMemberIDs = { _ in
            loads.withLock { $0 += 1 }
            if loads.withLock({ $0 }) == 1 { throw URLError(.timedOut) }
            return [kid.id]
        }
        client.recordParentalConsent = { _, _ in throw URLError(.badServerResponse) }  // already consented
        client.createInvite = { _ in "THESM-7KQ4-M9XP" }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(store.needsParentalConsent(kid))
        #expect(await store.consentAndInvite(kid) == "THESM-7KQ4-M9XP")
    }

    @Test(arguments: [RedeemResult.needsConsent, .ageMismatch])
    func newRedeemResultsExplainThemselves(result: RedeemResult) {
        #expect(result.message != nil)
    }
}
