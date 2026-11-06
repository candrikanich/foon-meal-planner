import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

/// "Delete everything about <name>" (#278): parents only, kids only, and the kid leaves this phone's family at once.
@MainActor
struct DeleteKidTests {
    private let me = UUID()
    private let kid = Member.fixture(firstName: "Nora", ageGroup: .kid, userID: UUID())
    private let grace = Member.fixture(firstName: "Grace", role: .planner)

    private func store(owner: UUID?, deleteKid: @escaping @Sendable (UUID) async throws -> Void = { _ in })
        async -> HouseholdStore {
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: owner)
        let members = [Member.fixture(firstName: "Ann", guardian: owner == me, userID: me), grace, kid]
        var client = HouseholdClient.fake(myHousehold: { household }, members: { _ in members })
        client.deleteKid = deleteKid
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        return store
    }

    @Test func onlyAParentAndOnlyForAKid() async {
        let parent = await store(owner: me)
        #expect(parent.canDeleteKid(kid))
        #expect(!parent.canDeleteKid(grace), "an adult deletes their own account; a parent removes them")
        let planner = await store(owner: UUID())
        #expect(!planner.canDeleteKid(kid), "planning rights don't include managing people")
    }

    @Test func theKidLeavesThisPhonesFamilyAtOnce() async {
        let asked = Mutex<[UUID]>([])
        let store = await store(owner: me, deleteKid: { id in asked.withLock { $0.append(id) } })
        #expect(await store.deleteKid(kid))
        #expect(asked.withLock { $0 } == [kid.id])
        #expect(!store.members.contains { $0.id == kid.id })
        #expect(store.errorMessage == nil)
    }

    @Test func anotherParentGettingThereFirstIsStillDone() async {
        let store = await store(owner: me, deleteKid: { _ in throw PostgrestError(code: "P0002", message: "gone") })
        #expect(await store.deleteKid(kid))
        #expect(!store.members.contains { $0.id == kid.id })
    }

    @Test func aRefusalKeepsThemAndSaysWhoCan() async {
        let store = await store(owner: me, deleteKid: { _ in throw PostgrestError(code: "42501", message: "no") })
        #expect(!(await store.deleteKid(kid)))
        #expect(store.members.contains { $0.id == kid.id })
        #expect(store.errorMessage?.contains("Only a parent") == true)
    }

    @Test func aLostConnectionKeepsThemAndSaysSo() async {
        let store = await store(owner: me, deleteKid: { _ in throw URLError(.notConnectedToInternet) })
        #expect(!(await store.deleteKid(kid)))
        #expect(store.members.contains { $0.id == kid.id })
        #expect(store.errorMessage?.contains("connection") == true)
    }
}
