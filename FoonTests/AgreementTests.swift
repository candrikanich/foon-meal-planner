import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

/// `my_agreements` and `my_access_hold` as the database sends them (#277).
struct AgreementStatusTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PostgrestClient.Configuration.jsonDecoder.decode(type, from: Data(json.utf8))
    }

    @Test func dormantBeforeAHousehold() throws {
        let status = try decode(AgreementStatus.self, """
        {"terms":{"current":null,"agreed":null,"satisfied":true,"summary":null},
         "privacy":{"current":null,"agreed":null,"satisfied":true,"summary":null},
         "allergy":null,"kids_held":[]}
        """)
        #expect(status == .dormant)
    }

    @Test func dormantWithAHousehold() throws {
        let status = try decode(AgreementStatus.self, """
        {"terms":{"current":null,"agreed":null,"satisfied":true,"summary":null},
         "privacy":{"current":null,"agreed":null,"satisfied":true,"summary":null},
         "allergy":{"current":null,"summary":null,"consented":true,"household_current":true,"held":false,
                    "own_current":true,"own_version":null,"own_summary":null},
         "kids_held":[]}
        """)
        #expect(status.allergy?.consented == true)
        #expect(status.allergy?.householdCurrent == true)
        #expect(status.kidsHeld.isEmpty)
    }

    @Test func aHeldKidForAParent() throws {
        let status = try decode(AgreementStatus.self, """
        {"terms":{"current":"terms-draft-v1","agreed":"terms-draft-v1","satisfied":true,"summary":"Rules."},
         "privacy":{"current":"privacy-draft-v1","agreed":null,"satisfied":false,"summary":"What Foon keeps."},
         "allergy":{"current":"allergy-data-v2","summary":"Names who receives them.","consented":true,
                    "household_current":false,"held":true,"own_current":true,"own_version":"own-allergy-v1",
                    "own_summary":"Adults agree for themselves."},
         "kids_held":[{"member_id":"6B1A2B49-8F7C-4E52-9C1F-3A1D2E4F5A61","first_name":"Owen",
                       "held_at":"2026-11-19T15:00:00.123456+00:00","emailed_at":null,"reminded_at":null,
                       "held_version":"parental-invite-v1","required_version":"parental-invite-v3",
                       "summary":"Confirms by email.","emailed_me_at":"2026-11-19T15:05:00+00:00"}]}
        """)
        let kid = try #require(status.kidsHeld.first)
        #expect(kid.firstName == "Owen")
        #expect(kid.requiredVersion == "parental-invite-v3")
        #expect(kid.emailedAt == nil)
        #expect(kid.emailedMeAt != nil)
        #expect(status.privacy.satisfied == false)
        #expect(status.allergy?.held == true)
    }

    @Test func aHeldKidsOwnDevice() throws {
        let hold = try decode(AccessHold?.self, """
        {"household_name":"The Smiths","first_name":"Nora","held_at":"2026-11-19T15:00:00+00:00"}
        """)
        #expect(hold?.firstName == "Nora")
        #expect(try decode(AccessHold?.self, "null") == nil, "an account that isn't held")
    }

    @Test func agreeingCountsAtOnce() {
        let accepted = AgreementStatus.previewTermsNew.acceptingTerms()
        #expect(accepted.terms.satisfied && accepted.privacy.satisfied)
        #expect(accepted.terms.agreed == "terms-draft-v1")
    }

    @Test func theVersionsMatchTheRegistry() {
        // supabase/migrations/20261117000000_agreements.sql registers these.
        #expect(OwnAllergyConsent.textVersion == "own-allergy-v1")
        #expect(AllergyConsent.covers == ["allergy-data-v1", "allergy-data-v2"])
    }

    @Test func theClientFitsTheLog() {
        #expect(AppVersion.client.count <= 40, "accept_agreements refuses more")
    }
}

/// What gets asked, decided from what's in force. Dormant asks nothing (#277).
struct AgreementPromptsTests {
    private typealias Status = AgreementStatus

    private func withAllergy(householdCurrent: Bool = true, current: String? = AllergyConsent.textVersion,
                             consented: Bool = true, ownCurrent: Bool = true,
                             ownVersion: String? = OwnAllergyConsent.textVersion) -> Status {
        Status(terms: .dormant, privacy: .dormant, allergy: Status.Allergy(
            current: current, summary: "What changed.", consented: consented, householdCurrent: householdCurrent,
            held: !householdCurrent, ownCurrent: ownCurrent, ownVersion: ownVersion, ownSummary: "Your own."
        ), kidsHeld: [])
    }

    private let dormantWithHousehold = Status(terms: .dormant, privacy: .dormant, allergy: Status.Allergy(
        current: nil, summary: nil, consented: true, householdCurrent: true, held: false, ownCurrent: true,
        ownVersion: nil, ownSummary: nil
    ), kidsHeld: [])

    @Test(arguments: [true, false])
    func dormantAsksNothing(isParent: Bool) {
        for status in [Status.dormant, dormantWithHousehold] {
            #expect(AgreementPrompts.termsGate(status, isAdult: true, creating: false, justJoined: false) == nil)
            #expect(AgreementPrompts.termsGate(status, isAdult: true, creating: true, justJoined: false) == nil)
            #expect(AgreementPrompts.cards(status, isAdult: true, isParent: isParent, hasOwnAllergies: true).isEmpty)
            #expect(AgreementPrompts.addBlock(status, ownProfile: !isParent) == nil)
        }
    }

    @Test func theFirstTermsGateSaysWhereItWasAgreed() throws {
        let status = Status.previewTermsNew
        let creating = try #require(
            AgreementPrompts.termsGate(status, isAdult: true, creating: true, justJoined: false)
        )
        #expect(creating.firstTime)
        #expect(creating.context == .createHousehold)
        #expect(creating.terms == "terms-draft-v1" && creating.privacy == "privacy-draft-v1")
        let joined = AgreementPrompts.termsGate(status, isAdult: true, creating: false, justJoined: true)
        #expect(joined?.context == .join)
        let later = AgreementPrompts.termsGate(status, isAdult: true, creating: false, justJoined: false)
        #expect(later?.context == .nextLaunch)
    }

    @Test func aReplacedTermsVersionIsAskedAgain() throws {
        var status = Status.previewTermsNew
        status.terms = Status.Account(current: "terms-v2", agreed: "terms-draft-v1", satisfied: false,
                                      summary: "Withdrawing is clearer.")
        status.privacy = Status.Account(current: "privacy-draft-v1", agreed: "privacy-draft-v1", satisfied: true,
                                        summary: "Unchanged.")
        let gate = try #require(AgreementPrompts.termsGate(status, isAdult: true, creating: false, justJoined: true))
        #expect(!gate.firstTime)
        #expect(gate.context == .changed)
        #expect(gate.summaries == ["Withdrawing is clearer."], "only what needs agreeing again")
    }

    @Test func kidsAndTheAgreedSeeNoTermsGate() {
        #expect(AgreementPrompts.termsGate(.previewTermsNew, isAdult: false, creating: false, justJoined: true) == nil)
        let agreed = Status.previewTermsNew.acceptingTerms()
        #expect(AgreementPrompts.termsGate(agreed, isAdult: true, creating: false, justJoined: false) == nil)
    }

    @Test func onlyOneOfTermsAndPrivacyInForceAsksNothing() {
        var status = Status.previewTermsNew
        status.privacy = .dormant
        #expect(AgreementPrompts.termsGate(status, isAdult: true, creating: false, justJoined: false) == nil,
                "accept_agreements needs both versions")
    }

    @Test func aParentReviewsNewAllergyWording() {
        let cards = AgreementPrompts.cards(withAllergy(householdCurrent: false), isAdult: true, isParent: true,
                                           hasOwnAllergies: true)
        #expect(cards == [.allergyAgreement(summary: "What changed.")])
    }

    @Test func wordingThisBuildCantShowAsksForAnUpdate() {
        let status = withAllergy(householdCurrent: false, current: "allergy-data-v3")
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: true, hasOwnAllergies: false) == [.updateFoon])
        #expect(AgreementPrompts.addBlock(status, ownProfile: false) == .updateFoon)
    }

    @Test func otherAdultsReadItAndKidsSeeNothing() {
        let status = withAllergy(householdCurrent: false)
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: false, hasOwnAllergies: false)
                == [.allergyWaitingOnParent(summary: "What changed.")])
        #expect(AgreementPrompts.cards(status, isAdult: false, isParent: false, hasOwnAllergies: true).isEmpty)
    }

    @Test func aFamilyWithAllergyAlertsOffIsntAsked() {
        let status = withAllergy(householdCurrent: false, consented: false, ownCurrent: false)
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: true, hasOwnAllergies: true).isEmpty)
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: false, hasOwnAllergies: true).isEmpty)
        #expect(AgreementPrompts.addBlock(status, ownProfile: true) == nil)
    }

    @Test func anAdultWithAllergiesIsAskedForTheirOwnSay() {
        let status = withAllergy(ownCurrent: false)
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: false, hasOwnAllergies: true)
                == [.ownAllergies(summary: "Your own.")])
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: false, hasOwnAllergies: false).isEmpty,
                "no allergies, nothing to keep")
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: true, hasOwnAllergies: true).isEmpty,
                "a parent's own agreement covers them")
        let newer = withAllergy(ownCurrent: false, ownVersion: "own-allergy-v2")
        #expect(AgreementPrompts.cards(newer, isAdult: true, isParent: false, hasOwnAllergies: true) == [.updateFoon])
    }

    @Test func oneUpdateCardEvenWhenBothAreNewer() {
        let status = withAllergy(householdCurrent: false, current: "allergy-data-v3", ownCurrent: false,
                                 ownVersion: "own-allergy-v2")
        #expect(AgreementPrompts.cards(status, isAdult: true, isParent: true, hasOwnAllergies: true) == [.updateFoon])
    }

    @Test func heldKidsAreForParentsOnly() {
        let status = Status.previewHeld
        let parent = AgreementPrompts.cards(status, isAdult: true, isParent: true, hasOwnAllergies: false)
        #expect(parent.contains(.kidHeld(status.kidsHeld[0])))
        let adult = AgreementPrompts.cards(status, isAdult: true, isParent: false, hasOwnAllergies: false)
        #expect(!adult.contains { if case .kidHeld = $0 { true } else { false } })
    }

    @Test func addingDuringAHold() {
        let held = withAllergy(householdCurrent: false)
        #expect(AgreementPrompts.addBlock(held, ownProfile: false) == nil, "a parent's Agree and save agrees")
        #expect(AgreementPrompts.addBlock(held, ownProfile: true) == .waitingOnParent)
        #expect(AgreementPrompts.addBlock(withAllergy(ownCurrent: false), ownProfile: true) == .ownAgreementNeeded)
        #expect(AgreementPrompts.addBlock(withAllergy(ownCurrent: false), ownProfile: false) == nil)
    }
}

/// The store's side of the agreements (#277): the held phase, the Terms gate, and held kids needing consent again.
@MainActor
struct HouseholdStoreAgreementTests {
    @Test func aHeldKidsDeviceWaitsForAParent() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.accessHold = { .preview }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        #expect(store.phase == .held(.preview))
    }

    @Test func withNoHoldItsStartOrJoinAsBefore() async {
        let store = HouseholdStore(userID: UUID(), client: .preview(household: nil, members: []))
        await store.load()
        #expect(store.phase == .needsHousehold)
        #expect(store.termsGate(creating: true) == nil, "dormant")
    }

    @Test func aDormantHouseholdLoadsAsBefore() async {
        let store = HouseholdStore.preview()
        await store.load()
        #expect(store.household?.id == Household.sample.id)
        #expect(store.termsGate() == nil)
        #expect(store.agreementCards(hasOwnAllergies: true).isEmpty)
        let nora = Member.sampleFamily[4]
        #expect(store.needsParentalConsent(nora), "no consent yet, as before")
    }

    @Test func agreementsThatCantBeReadAskNothing() async {
        var client = HouseholdClient.preview()
        client.agreements = { _ in throw URLError(.notConnectedToInternet) }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        #expect(store.household?.id == Household.sample.id, "the household still loads")
        #expect(store.termsGate() == nil)
    }

    @Test func aHeldKidNeedsConsentAgain() async {
        let owen = Member.sampleFamily[3]
        var client = HouseholdClient.preview()
        client.parentalConsentMemberIDs = { _ in [owen.id] }
        client.agreements = { _ in .previewHeld }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        #expect(store.needsParentalConsent(owen), "consent is active, but to wording no longer in force")
        #expect(store.kidHold(for: owen)?.firstName == "Owen")
        #expect(store.consentStep(for: owen) == .emailMe)
        #expect(store.consentStep(for: owen).button(renewing: true) == "Email me the form")
    }

    @Test func aRenewalAgreedInTheEmailMovesOnToInvite() async {
        let owen = Member.sampleFamily[3]
        let renewed = LockedBox(false)
        var client = HouseholdClient.preview()
        client.parentalConsentMemberIDs = { _ in [owen.id] }
        client.agreements = { _ in renewed.value ? .dormant : .previewHeld }
        client.requestParentalConsent = { _, _ in
            renewed.set(true)
            return .alreadyConsented
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        #expect(store.needsParentalConsent(owen))
        await store.askForConsent(owen)
        #expect(!store.needsParentalConsent(owen), "the hold ended, so Invite shows")
    }

    @Test func agreeingToTermsLetsTheAdultIn() async throws {
        let offline = LockedBox(false)
        var client = HouseholdClient.preview()
        client.agreements = { _ in
            if offline.value { throw URLError(.notConnectedToInternet) }
            return .previewTermsNew
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        let gate = try #require(store.termsGate())
        #expect(gate.context == .nextLaunch)
        offline.set(true)
        await store.recordTermsAccepted()
        #expect(store.termsGate() == nil, "even when the reload after Agree doesn't get through")
    }

    @Test func joiningLogsTheJoin() async {
        var client = HouseholdClient.preview()
        client.agreements = { _ in .previewTermsNew }
        client.myHousehold = { .sample }
        client.redeemInvite = { _ in .claimed }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.redeem("THESM-7KQ4-M9XP")
        #expect(store.termsGate()?.context == .join)
    }

    @Test func aKidJoiningSeesNoTermsGate() async {
        let kid = UUID()
        var family = Member.sampleFamily
        family[4].userID = kid
        var client = HouseholdClient.preview(members: family)
        client.agreements = { _ in .previewTermsNew }
        let store = HouseholdStore(userID: kid, client: client)
        await store.load()
        #expect(store.termsGate() == nil)
    }

    @Test func acceptingLogsTheVersionsAndContext() async {
        let logged = LockedBox<[String]>([])
        var client = HouseholdClient.preview()
        client.acceptAgreements = { terms, privacy, context, version in
            logged.set([terms, privacy, context.rawValue, version])
        }
        let actions = AgreementActions()
        #expect(await actions.accept(.previewFirstTime, using: client))
        #expect(logged.value == ["terms-draft-v1", "privacy-draft-v1", "next_launch", AppVersion.client])
    }

    @Test func agreeingForYourselfLogsYourWording() async {
        let logged = LockedBox<String?>(nil)
        var client = HouseholdClient.preview()
        client.agreeToOwnAllergies = { _, wording in logged.set(wording) }
        #expect(await AgreementActions().agreeForMyself(UUID(), using: client))
        #expect(logged.value == OwnAllergyConsent.textVersion)
    }

    @Test func aRefusedAgreementSaysSoWithoutBlamingTheConnection() async {
        var client = HouseholdClient.preview()
        client.grantAllergyConsent = { _, _ in throw PostgrestError(code: "42501", message: "refused") }
        let actions = AgreementActions()
        #expect(await !actions.agreeForHousehold(Household.sample.id, using: client))
        #expect(actions.errorMessage == "Foon can't record this for you now. Try again in a moment, or sign in again.")
    }
}

/// A value a `@Sendable` fake writes and a test reads.
final class LockedBox<Value: Sendable>: Sendable {
    private let lock: Mutex<Value>
    init(_ value: Value) { lock = Mutex(value) }
    var value: Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
}
