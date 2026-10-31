import Foundation
import Synchronization
import Testing
@testable import Foon

@MainActor
struct HouseholdStoreTests {
    private let me = UUID()
    private let household = Household(id: UUID(), name: "The Smiths", emoji: "🌮", owner: nil)

    @Test func theExportIsAReadableJSONFile() async throws {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            exportHousehold: { _ in Data(#"{"meals":[{"name":"Tacos"}],"household":{"name":"The Smiths"}}"#.utf8) }
        ))
        await store.load()
        let url = try #require(await store.exportFile())
        #expect(url.pathExtension == "json")
        #expect(url.lastPathComponent.hasPrefix("Foon - The Smiths"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"), "pretty-printed, so a person can read it")
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect((decoded?["household"] as? [String: Any])?["name"] as? String == "The Smiths")
    }

    @Test func aFailedExportSaysSo() async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            exportHousehold: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        #expect(await store.exportFile() == nil)
        #expect(store.errorMessage != nil)
    }

    @Test func deletingTheHouseholdSendsYouBackToStartOne() async {
        let household = Household(id: UUID(), name: "Sample", emoji: nil, owner: me)
        let gone = Mutex(false)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { gone.withLock { $0 } ? nil : household },
            deleteHousehold: { gone.withLock { $0 = true } }
        ))
        await store.load()
        #expect(await store.deleteHousehold())
        #expect(store.phase == .needsHousehold, "your account stays; you start or join another household")
    }

    @Test func aDeletedHouseholdIsGoneEvenIfTheReloadFails() async {
        let household = Household(id: UUID(), name: "Sample", emoji: nil, owner: me)
        let deleted = Mutex(false)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: {
                if deleted.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                return household
            },
            members: { _ in [Member.fixture(firstName: "Ann")] },
            deleteHousehold: { deleted.withLock { $0 = true } }
        ))
        await store.load()
        #expect(await store.deleteHousehold())
        #expect(store.phase == .needsHousehold, "the server erased it: don't keep showing it")
        #expect(store.members.isEmpty)
    }

    @Test func notTheOwnerAnyMoreSaysSoAndReloads() async {
        let household = Household(id: UUID(), name: "Sample", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            deleteHousehold: { throw HouseholdDeletionError.notOwner }
        ))
        await store.load()
        #expect(!(await store.deleteHousehold()))
        #expect(store.errorMessage?.contains("not its owner") == true, "not a connection problem")
    }

    @Test func theSampleShortcutIsOnlyForAHouseholdNobodyElseHasJoined() async {
        var settings = HouseholdSettings()
        settings.isSample = true
        let household = Household(id: UUID(), name: "The Sample Family", emoji: nil, owner: me, settings: settings)
        let mine = Member.fixture(firstName: "Ann", userID: me)
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let alone = HouseholdStore(userID: me, client: .fake(myHousehold: { household }, members: { _ in [mine, kid] }))
        await alone.load()
        #expect(alone.isUnsharedSample)
        let spouse = Member.fixture(firstName: "Ben", userID: UUID())
        let shared = HouseholdStore(userID: me, client: .fake(myHousehold: { household },
                                                              members: { _ in [mine, kid, spouse] }))
        await shared.load()
        #expect(!shared.isUnsharedSample, "once someone else has joined, it's their household too: type the name")
    }

    @Test func aFailedHouseholdDeleteKeepsItAndSaysSo() async {
        let household = Household(id: UUID(), name: "Sample", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            deleteHousehold: { throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        #expect(!(await store.deleteHousehold()))
        #expect(store.household?.id == household.id)
        #expect(store.errorMessage?.contains("didn't finish") == true)
    }

    @Test func aHouseholdThatIsGoneSendsYouBackToStartOne() async {
        let household = household
        let gone = Mutex(false)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { gone.withLock { $0 } ? nil : household }))
        await store.load()
        #expect(store.household?.id == household.id)
        gone.withLock { $0 = true }  // the owner deleted it, or this person was removed
        await store.load()
        #expect(store.phase == .needsHousehold, "the gate then shows Create household, which wipes the cache")
    }

    @Test func anOfflineReloadKeepsTheHousehold() async {
        let household = household
        let offline = Mutex(false)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: {
            if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return household
        }))
        await store.load()
        offline.withLock { $0 = true }
        await store.load()
        #expect(store.household?.id == household.id, "no connection is not a missing household: the cache stays")
    }

    @Test func withNoHouseholdTheUserCreatesOne() async {
        let store = HouseholdStore(userID: me, client: .fake())
        await store.load()
        #expect(store.phase == .needsHousehold)
    }

    @Test func createsTheHouseholdAndLoadsItsMembers() async {
        let owner = Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: me)
        let created = Household(id: household.id, name: "The Smiths", emoji: "🌮", owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { name, emoji, firstName, _ in
                #expect(name == "The Smiths")
                #expect(emoji == "🌮")
                #expect(firstName == "Ann")
                return created
            },
            members: { _ in [owner] }
        ))
        await store.createHousehold(name: " The Smiths ", emoji: "🌮", firstName: "Ann")
        #expect(store.household?.id == created.id)
        #expect(store.household?.planningSettings.onboarded == false, "a new household starts onboarding")
        #expect(store.members == [owner])
    }

    @Test func refusesAnInvalidHouseholdWithoutCallingTheServer() async {
        let store = HouseholdStore(userID: me, client: .fake(createHousehold: { _, _, _, _ in
            Issue.record("should not be called")
            throw URLError(.badURL)
        }))
        await store.createHousehold(name: "  ", emoji: nil, firstName: "Ann")
        #expect(store.errorMessage != nil)
    }

    @Test func hidesRemovedMembersAndListsGuardiansFirst() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let parent = Member.fixture(firstName: "Ann", guardian: true, userID: me)
        let gone = Member.fixture(firstName: "Rita", status: .removed)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }, members: { _ in [kid, gone, parent] }))
        await store.load()
        #expect(store.visibleMembers.map(\.firstName) == ["Ann", "Nora"])
    }

    @Test func guardiansManageEveryone() async {
        let parent = Member.fixture(firstName: "Ann", guardian: true, userID: me)
        let grandma = Member.fixture(firstName: "Grace", role: .planner)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }, members: { _ in [parent, grandma] }))
        await store.load()
        #expect(store.canManagePeople)
        #expect(store.editScope(for: grandma) == .everything)
    }

    @Test func aPlannerWhoIsNotAGuardianDoesNotManagePeople() async {
        let grandmaUser = UUID()
        let parent = Member.fixture(firstName: "Ann", guardian: true)
        let grandma = Member.fixture(firstName: "Grace", role: .planner, userID: grandmaUser)
        let store = HouseholdStore(userID: grandmaUser, client: .fake(
            myHousehold: { household },
            members: { _ in [parent, grandma] }
        ))
        await store.load()
        #expect(!store.canManagePeople)
        #expect(store.editScope(for: grandma) == .avatarOnly)
    }

    @Test func aNonGuardianEditsOnlyTheirOwnAvatar() async {
        let parent = Member.fixture(firstName: "Ann", guardian: true)
        let kid = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: me)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }, members: { _ in [parent, kid] }))
        await store.load()
        #expect(!store.canManagePeople)
        #expect(store.editScope(for: kid) == .avatarOnly)
        #expect(store.editScope(for: parent) == .none)
    }

    @Test func theOwnerCanNeverBeRemoved() async {
        let owned = Household(id: household.id, name: "The Smiths", emoji: nil, owner: me)
        let owner = Member.fixture(firstName: "Ann", guardian: true, userID: me)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { owned }, members: { _ in [owner] }))
        await store.load()
        #expect(!store.canRemove(owner))
    }

    @Test func savesAnEditedMemberAndReplacesItInTheList() async throws {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let parent = Member.fixture(firstName: "Ann", guardian: true, userID: me)
        var away = kid
        away.status = .away
        away.awayUntil = CalendarDay(year: 2026, month: 12, day: 20)
        let saved = away
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in [parent, kid] },
            updateMember: { id, changes in
                #expect(id == kid.id)
                #expect(changes == MemberChanges(status: .away, awayUntil: .some(CalendarDay(year: 2026, month: 12, day: 20))))
                return saved
            }
        ))
        await store.load()
        var draft = MemberDraft(kid)
        draft.status = .away
        draft.awayUntil = CalendarDay(year: 2026, month: 12, day: 20)
        #expect(await store.save(draft, editing: kid))
        #expect(store.members.first { $0.id == kid.id } == saved)
    }

    @Test func aFailedSaveKeepsTheListAndShowsAMessage() async {
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in [kid] },
            updateMember: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        var draft = MemberDraft(kid)
        draft.firstName = "Nori"
        #expect(!(await store.save(draft, editing: kid)))
        #expect(store.members == [kid])
        #expect(store.errorMessage != nil)
    }

    @Test func theOwnerCannotChangeTheirOwnAgeOrParentStatus() async {
        let owned = Household(id: household.id, name: "The Smiths", emoji: nil, owner: me)
        let owner = Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: me)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { owned }, members: { _ in [owner] }))
        await store.load()
        #expect(store.editScope(for: owner) == .ownProfileAsOwner)
    }

    @Test func anotherParentEditsOnlyTheOwnersNameAndAvatar() async {
        let ownerUser = UUID()
        let owned = Household(id: household.id, name: "The Smiths", emoji: nil, owner: ownerUser)
        let owner = Member.fixture(firstName: "Ann", guardian: true, userID: ownerUser)
        let secondParent = Member.fixture(firstName: "Ben", guardian: true, userID: me)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { owned }, members: { _ in [owner, secondParent] }))
        await store.load()
        #expect(store.editScope(for: owner) == .nameAndAvatar)
        #expect(store.editScope(for: secondParent) == .everything)
        #expect(!store.canRemove(secondParent), "parents don't remove themselves from inside the app")
    }

    @Test func savesOnlyWhatChanged() async throws {
        let kid = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: me)
        let changed = Mutex<MemberChanges?>(nil)
        var updated = kid
        updated.avatar = "🦊"
        let saved = updated
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in [kid] },
            updateMember: { _, changes in
                changed.withLock { $0 = changes }
                return saved
            }
        ))
        await store.load()
        var draft = MemberDraft(kid)
        draft.avatar = "🦊"
        #expect(await store.save(draft, editing: kid))
        #expect(changed.withLock { $0 } == MemberChanges(avatar: .some("🦊")))
    }

    @Test func savingWithoutChangesSkipsTheServer() async {
        let kid = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: me)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in [kid] },
            updateMember: { _, _ in
                Issue.record("should not be called")
                throw URLError(.badURL)
            }
        ))
        await store.load()
        #expect(await store.save(MemberDraft(kid), editing: kid))
    }

    @Test func aCreatedHouseholdIsReadyEvenIfMembersFailToLoad() async {
        let created = Household(id: household.id, name: "The Smiths", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { _, _, _, _ in created },
            members: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.createHousehold(name: "The Smiths", emoji: nil, firstName: "Ann")
        #expect(store.household?.id == created.id)
        #expect(store.household?.planningSettings.onboarded == false, "a new household starts onboarding")
        #expect(store.canManagePeople, "the owner manages people before their profile loads")
    }

    @Test func reloadingClearsAnOldError() async {
        let failing = Mutex(true)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: {
            if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return nil
        }))
        await store.load()
        #expect(store.phase == .failed)
        failing.withLock { $0 = false }
        await store.load()
        #expect(store.phase == .needsHousehold)
        #expect(store.errorMessage == nil)
    }

    @Test func addsAMember() async {
        let added = Member.fixture(firstName: "Owen")
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in [] },
            addMember: { householdID, draft in
                #expect(householdID == household.id)
                #expect(draft.firstName == "Owen")
                return added
            }
        ))
        await store.load()
        var draft = MemberDraft()
        draft.firstName = "Owen"
        #expect(await store.save(draft, editing: nil))
        #expect(store.members == [added])
    }
}

extension HouseholdClient {
    static func fake(
        myHousehold: @escaping @Sendable () async throws -> Household? = { nil },
        createHousehold: @escaping @Sendable (String, String?, String, HouseholdSettings) async throws -> Household = { _, _, _, _ in
            throw URLError(.unknown)
        },
        members: @escaping @Sendable (UUID) async throws -> [Member] = { _ in [] },
        addMember: @escaping @Sendable (UUID, MemberDraft) async throws -> Member = { _, _ in throw URLError(.unknown) },
        updateMember: @escaping @Sendable (UUID, MemberChanges) async throws -> Member = { _, _ in throw URLError(.unknown) },
        grantAllergyConsent: @escaping @Sendable (UUID, String) async throws -> Void = { _, _ in },
        setAllergies: @escaping @Sendable (UUID, [Allergen], [String]) async throws -> Void = { _, _, _ in },
        updateSettings: @escaping @Sendable (UUID, HouseholdSettings) async throws -> Void = { _, _ in },
        updateKitchen: @escaping @Sendable (UUID, HouseholdSettings.Kitchen) async throws -> Void = { _, _ in },
        exportHousehold: @escaping @Sendable (UUID) async throws -> Data = { _ in Data("{}".utf8) },
        deleteHousehold: @escaping @Sendable () async throws -> Void = { },
        addAwayDates: @escaping @Sendable (UUID, AwayDates) async throws -> [AwayDates] = { _, _ in [] },
        removeAwayDates: @escaping @Sendable (UUID, AwayDates) async throws -> [AwayDates] = { _, _ in [] },
        attendanceTemplates: @escaping @Sendable (UUID) async throws -> [AttendanceTemplate] = { _ in [] },
        saveAttendanceTemplate: @escaping @Sendable (UUID, String) async throws -> AttendanceTemplate = { _, _ in
            throw URLError(.unknown)
        },
        applyAttendanceTemplate: @escaping @Sendable (UUID) async throws -> Void = { _ in },
        deleteAttendanceTemplate: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) -> HouseholdClient {
        HouseholdClient(
            myHousehold: myHousehold,
            createHousehold: createHousehold,
            members: members,
            addMember: addMember,
            updateMember: updateMember,
            createInvite: { _ in throw URLError(.unknown) },
            redeemInvite: { _ in .invalid },
            invitedMemberIDs: { _ in [] },
            parentalConsentMemberIDs: { _ in [] },
            recordParentalConsent: { _, _ in },
            revokeParentalConsent: { _ in },
            grantAllergyConsent: grantAllergyConsent,
            setAllergies: setAllergies,
            updateSettings: updateSettings,
            updateKitchen: updateKitchen,
            exportHousehold: exportHousehold,
            deleteHousehold: deleteHousehold,
            addAwayDates: addAwayDates,
            removeAwayDates: removeAwayDates,
            attendanceTemplates: attendanceTemplates,
            saveAttendanceTemplate: saveAttendanceTemplate,
            applyAttendanceTemplate: applyAttendanceTemplate,
            deleteAttendanceTemplate: deleteAttendanceTemplate
        )
    }
}

struct AccountDeletionOutcomeTests {
    private let me = UUID()

    @Test func theOwnerDeletesTheHousehold() {
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me)
        #expect(AccountDeletion.outcome(household: household, me: nil, userID: me) == .household(name: "The Smiths"))
        #expect(AccountDeletion.household(name: "The Smiths").buttonTitle == "Delete my account and household",
                "the button says the household goes too")
        #expect(AccountDeletion.adult(householdName: "The Smiths").buttonTitle == "Delete my account")
    }

    @Test func confirmingADeleteNeedsTheHouseholdsName() {
        #expect(HouseholdDeletion.confirms(" the smiths ", name: "The Smiths"), "case and spaces don't matter")
        #expect(!HouseholdDeletion.confirms("Smiths", name: "The Smiths"))
        #expect(!HouseholdDeletion.confirms("", name: "The Smiths"))
    }

    @Test func otherAdultsLeaveAndKidsKeepTheirProfile() {
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: UUID())
        let adult = Member.fixture(firstName: "Ben", userID: me)
        let kid = Member.fixture(firstName: "Nora", ageGroup: .kid, userID: me)
        #expect(AccountDeletion.outcome(household: household, me: adult, userID: me) == .adult(householdName: "The Smiths"))
        #expect(AccountDeletion.outcome(household: household, me: kid, userID: me) == .kid)
        #expect(AccountDeletion.outcome(household: nil, me: nil, userID: me) == .noHousehold)
    }
}
