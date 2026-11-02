import Foundation
import PostgREST
import Synchronization
import Testing
@testable import Foon

@MainActor
struct MemberPresetTests {
    private let me = UUID()
    private let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: nil)

    private func person(_ name: String, kid: Bool = false, claimed: Bool = true, parent: Bool = false,
                        preset: HouseholdSettings.NotificationPreset? = nil) -> Member {
        var member = Member.fixture(householdID: household.id, firstName: name, ageGroup: kid ? .kid : .adult,
                                    guardian: parent, userID: claimed ? UUID() : nil)
        member.notificationPrefs = NotificationPrefs(preset: preset)
        return member
    }

    // MARK: - Who sets whose

    @Test func anAdultSetsTheirOwnAndAParentAKidsOrAnUnclaimedProfiles() {
        let parent = person("Ann", parent: true)
        let adult = person("Ben")
        let kid = person("Kim", kid: true)
        let unclaimedAdult = person("Uma", claimed: false)
        let unclaimedKid = person("Nora", kid: true, claimed: false)

        #expect(MemberPresetRules.canSet(adult, me: adult, isParent: false), "their own")
        #expect(MemberPresetRules.canSet(parent, me: parent, isParent: true))
        #expect(!MemberPresetRules.canSet(kid, me: kid, isParent: false), "a kid doesn't set their own")
        #expect(MemberPresetRules.canSet(kid, me: parent, isParent: true))
        #expect(MemberPresetRules.canSet(unclaimedKid, me: parent, isParent: true))
        #expect(MemberPresetRules.canSet(unclaimedAdult, me: parent, isParent: true), "nobody else can speak for it")
        #expect(!MemberPresetRules.canSet(adult, me: parent, isParent: true), "not another adult's, even as a parent")
        #expect(!MemberPresetRules.canSet(kid, me: adult, isParent: false), "a planner who isn't a parent can't")
        #expect(!MemberPresetRules.canSet(unclaimedAdult, me: adult, isParent: false))
        var removed = kid
        removed.status = .removed
        #expect(!MemberPresetRules.canSet(removed, me: parent, isParent: true))
    }

    @Test func aKidsChoicesStopAtTheFamilys() {
        #expect(MemberPresetRules.choices(for: person("Ben"), family: .light) == [.light, .balanced, .engaged])
        #expect(MemberPresetRules.choices(for: person("Kim", kid: true), family: .balanced) == [.light, .balanced])
        #expect(MemberPresetRules.choices(for: person("Kim", kid: true), family: .light) == [.light])
    }

    @Test func familySaysWhatTheyGet() {
        #expect(MemberPresetRules.title(for: person("Ben"), family: .balanced) == "Same as family (Balanced)")
        #expect(MemberPresetRules.title(for: person("Ben", preset: .engaged), family: .balanced) == "Engaged")
        #expect(MemberPresetRules.title(for: person("Kim", kid: true, preset: .light), family: .balanced) == "Light")
        #expect(MemberPresetRules.title(for: person("Kim", kid: true, preset: .engaged), family: .balanced)
            == "Same as family (Balanced)", "a kid's above the family's is the family's")
    }

    @Test func theChecksFollowWhatCounts() {
        #expect(MemberPresetRules.selected(for: person("Ben"), family: .balanced) == nil)
        #expect(MemberPresetRules.selected(for: person("Ben", preset: .light), family: .balanced) == .light)
        #expect(MemberPresetRules.selected(for: person("Kim", kid: true, preset: .engaged), family: .balanced) == nil,
                "a kid's above the family's checks Same as family, as the row says")
        #expect(MemberPresetRules.selected(for: person("Kim", kid: true, preset: .balanced), family: .balanced) == .balanced)
    }

    @Test func theDevicePlansByTheirOwn() {
        let ben = person("Ben", preset: .engaged)
        #expect(ReminderRules(member: ben, settings: HouseholdSettings()).weeklyBudget == 16)
        #expect(ReminderRules(member: person("Ben"), settings: HouseholdSettings()).weeklyBudget == 12)
    }

    // MARK: - Saving

    @Test func followingTheFamilySendsAnExplicitNull() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemberPresetParams(targetMember: UUID(),
                                                                                                  preset: nil))) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["target_member", "preset"])
        #expect(body?["preset"] is NSNull)
        let set = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemberPresetParams(targetMember: UUID(),
                                                                                                 preset: .light))) as? [String: Any]
        #expect(set?["preset"] as? String == "light")
    }

    @Test func savingShowsTheirNewPresetAtOnce() async {
        let ben = Member.fixture(householdID: household.id, firstName: "Ben", userID: me)
        let sent = Mutex<[HouseholdSettings.NotificationPreset?]>([])
        var client = HouseholdClient.fake(myHousehold: { [household] in household }, members: { _ in [ben] })
        client.setMemberPreset = { _, preset in sent.withLock { $0.append(preset) } }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()

        #expect(store.canSetPreset(ben))
        #expect(await store.setPreset(.light, for: ben))
        #expect(store.members.first?.notificationPrefs?.preset == .light)
        #expect(await store.setPreset(nil, for: ben))
        #expect(store.members.first?.notificationPrefs?.preset == nil)
        #expect(sent.withLock { $0 } == [.light, nil])
    }

    @Test func aRefusalSaysWho() async {
        let ben = Member.fixture(householdID: household.id, firstName: "Ben", userID: me)
        var client = HouseholdClient.fake(myHousehold: { [household] in household }, members: { _ in [ben] })
        client.setMemberPreset = { _, _ in throw PostgrestError(code: "42501", message: "no") }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(!(await store.setPreset(.engaged, for: ben)))
        #expect(store.errorMessage == "People set their own notifications; a parent sets a kid's.")
        #expect(store.members.first?.notificationPrefs?.preset == nil)
    }

    @Test(arguments: [
        ("22023", "A kid's notifications can't be more than the family's."),
        ("P0002", "They're no longer in the family."),
        ("08006", "Couldn't save notifications. Check your connection and try again.")
    ])
    func eachRefusalSaysWhy(code: String, says message: String) async {
        let ben = Member.fixture(householdID: household.id, firstName: "Ben", userID: me)
        var client = HouseholdClient.fake(myHousehold: { [household] in household }, members: { _ in [ben] })
        client.setMemberPreset = { _, _ in throw PostgrestError(code: code, message: "no") }
        let store = HouseholdStore(userID: me, client: client)
        await store.load()
        #expect(!(await store.setPreset(.light, for: ben)))
        #expect(store.errorMessage == message)
    }
}
