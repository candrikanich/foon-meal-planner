import Foundation

extension HouseholdStore {
    /// What the signed-in person may change on a member's profile. Mirrors the database rules
    /// (`members_guard_write`) so the UI never offers a change the server will refuse.
    enum EditScope: Equatable {
        /// A parent editing someone else: everything, including removal.
        case everything
        /// The owner editing themselves: not age or parent, which must stay adult and parent.
        case ownProfileAsOwner
        /// Another parent editing the owner's profile: name and avatar only.
        case nameAndAvatar
        /// Anyone else editing themselves.
        case avatarOnly
        case none

        var name: Bool { [.everything, .ownProfileAsOwner, .nameAndAvatar].contains(self) }
        var identity: Bool { self == .everything }
        var planning: Bool { [.everything, .ownProfileAsOwner].contains(self) }
        /// Everyone edits their own usual schedule; parents can change anyone's.
        var schedule: Bool { self != .none }
    }

    /// Whose allergies the signed-in person may change. Mirrors `set_member_allergies` and member_allergies' policies.
    enum AllergyScope: Equatable {
        /// A parent: anyone's, and they agree for the household to keep them.
        case asParent
        /// An adult who isn't a parent, on their own profile: they add and remove their own one at a time, under the
        /// household's agreement (#285). Kids' stay with their parents.
        case own
        case none
    }
}
