import Foundation

/// Someone's own notification preset (docs/spec.md → Notification presets): who may change it, and what they can pick.
/// The same rules as the server's `set_member_preset`; `ReminderRules.preset` reads the result.
enum MemberPresetRules {
    typealias Preset = HouseholdSettings.NotificationPreset

    /// An adult changes their own. A parent changes a kid's, or a profile nobody has claimed (nobody else can speak for it;
    /// once claimed, it's theirs). Nobody changes another adult's, parents and planners included, and a kid doesn't change
    /// their own.
    static func canSet(_ member: Member, me: Member?, isParent: Bool) -> Bool {
        guard member.status != .removed else { return false }
        if let me, me.id == member.id, member.userID != nil { return member.ageGroup == .adult }
        return isParent && (member.ageGroup == .kid || member.userID == nil)
    }

    /// Every preset for an adult; a kid's go no higher than the family's.
    static func choices(for member: Member, family: Preset) -> [Preset] {
        guard member.ageGroup == .kid else { return Preset.allCases }
        return Preset.allCases.filter { rank($0) <= rank(family) }
    }

    /// What Family shows: their own, or "Same as family (Balanced)".
    static func title(for member: Member, family: Preset) -> String {
        guard let own = member.notificationPrefs?.preset else {
            return String(localized: "Same as family (\(family.title))", comment: "A person's notifications follow the household's preset")
        }
        return ReminderRules.preset(member: member, household: family) == own
            ? own.title
            : String(localized: "Same as family (\(family.title))", comment: "A person's notifications follow the household's preset")
    }

    private static func rank(_ preset: Preset) -> Int { Preset.allCases.firstIndex(of: preset) ?? 0 }
}
