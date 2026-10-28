import Foundation

extension UUID {
    /// The signed-in person in previews: Ann, the owner and a parent.
    static let previewUser = UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!
}

extension Household {
    static let sample = Household(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a0")!, name: "The Smiths", emoji: "🌮", owner: .previewUser
    )
}

extension Member {
    static func fixture(
        id: UUID = UUID(),
        householdID: UUID = Household.sample.id,
        firstName: String = "Sam",
        avatar: String? = nil,
        ageGroup: AgeGroup = .adult,
        guardian: Bool = false,
        role: MemberRole = .member,
        status: MemberStatus = .active,
        awayUntil: CalendarDay? = nil,
        userID: UUID? = nil
    ) -> Member {
        Member(
            id: id, householdID: householdID, firstName: firstName, avatar: avatar, ageGroup: ageGroup,
            guardian: guardian, role: role, status: status, awayUntil: awayUntil, userID: userID
        )
    }

    /// A family for previews: two parents, a grandparent who plans, a teen away at camp, and a kid.
    static let sampleFamily: [Member] = [
        .fixture(firstName: "Ann", avatar: "🦉", guardian: true, role: .planner, userID: .previewUser),
        .fixture(firstName: "Ben", avatar: "🐻", guardian: true),
        .fixture(firstName: "Grace", avatar: "🌻", role: .planner),
        .fixture(firstName: "Owen", avatar: "🦊", ageGroup: .kid, status: .away,
                 awayUntil: CalendarDay(year: 2026, month: 12, day: 20)),
        .fixture(firstName: "Nora", avatar: "🐢", ageGroup: .kid)
    ]
}

extension HouseholdClient {
    /// Serves a fixed household and family; writes echo back what was sent.
    static func preview(household: Household? = .sample, members: [Member] = Member.sampleFamily) -> HouseholdClient {
        HouseholdClient(
            myHousehold: { household },
            createHousehold: { name, emoji, _, _ in Household(id: UUID(), name: name, emoji: emoji, owner: .previewUser) },
            members: { _ in members },
            addMember: { householdID, draft in
                .fixture(householdID: householdID, firstName: draft.firstName, avatar: draft.avatar,
                         ageGroup: draft.ageGroup, guardian: draft.guardian, role: draft.role)
            },
            updateMember: { memberID, changes in
                (members.first { $0.id == memberID } ?? .fixture(id: memberID)).applying(changes)
            },
            createInvite: { _ in "THESM-7KQ4-M9XP" },
            redeemInvite: { _ in .invalid },
            invitedMemberIDs: { _ in [] },
            parentalConsentMemberIDs: { _ in [] },
            recordParentalConsent: { _, _ in },
            revokeParentalConsent: { _ in }
        )
    }
}

extension HouseholdStore {
    /// A store as Ann (owner, parent) sees it, once `load()` runs.
    static func preview(household: Household? = .sample) -> HouseholdStore {
        HouseholdStore(userID: .previewUser, client: .preview(household: household))
    }
}
