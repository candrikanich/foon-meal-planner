import Foundation
import Synchronization
import Testing
@testable import Foon

@MainActor
struct HouseholdStoreTests {
    private let me = UUID()
    private let household = Household(id: UUID(), name: "The Smiths", emoji: "🌮", owner: nil)

    @Test func withNoHouseholdTheUserCreatesOne() async {
        let store = HouseholdStore(userID: me, client: .fake())
        await store.load()
        #expect(store.phase == .needsHousehold)
    }

    @Test func createsTheHouseholdAndLoadsItsMembers() async {
        let owner = Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: me)
        let created = Household(id: household.id, name: "The Smiths", emoji: "🌮", owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { name, emoji, firstName in
                #expect(name == "The Smiths")
                #expect(emoji == "🌮")
                #expect(firstName == "Ann")
                return created
            },
            members: { _ in [owner] }
        ))
        await store.createHousehold(name: " The Smiths ", emoji: "🌮", firstName: "Ann")
        #expect(store.phase == .ready(created))
        #expect(store.members == [owner])
    }

    @Test func refusesAnInvalidHouseholdWithoutCallingTheServer() async {
        let store = HouseholdStore(userID: me, client: .fake(createHousehold: { _, _, _ in
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
        #expect(await store.save(draft, editing: kid.id))
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
        #expect(!(await store.save(draft, editing: kid.id)))
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
        #expect(await store.save(draft, editing: kid.id))
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
        #expect(await store.save(MemberDraft(kid), editing: kid.id))
    }

    @Test func aCreatedHouseholdIsReadyEvenIfMembersFailToLoad() async {
        let created = Household(id: household.id, name: "The Smiths", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { _, _, _ in created },
            members: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.createHousehold(name: "The Smiths", emoji: nil, firstName: "Ann")
        #expect(store.phase == .ready(created))
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

private extension HouseholdClient {
    static func fake(
        myHousehold: @escaping @Sendable () async throws -> Household? = { nil },
        createHousehold: @escaping @Sendable (String, String?, String) async throws -> Household = { _, _, _ in
            throw URLError(.unknown)
        },
        members: @escaping @Sendable (UUID) async throws -> [Member] = { _ in [] },
        addMember: @escaping @Sendable (UUID, MemberDraft) async throws -> Member = { _, _ in throw URLError(.unknown) },
        updateMember: @escaping @Sendable (UUID, MemberChanges) async throws -> Member = { _, _ in throw URLError(.unknown) }
    ) -> HouseholdClient {
        HouseholdClient(
            myHousehold: myHousehold,
            createHousehold: createHousehold,
            members: members,
            addMember: addMember,
            updateMember: updateMember
,
            createInvite: { _ in throw URLError(.unknown) },
            redeemInvite: { _ in .invalid },
            invitedMemberIDs: { _ in [] }
        )
    }
}
