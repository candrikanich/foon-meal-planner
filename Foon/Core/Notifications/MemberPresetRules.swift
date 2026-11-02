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

    /// Their own preset as it counts, or nil when they follow the family's: nothing saved, or a kid's above the family's,
    /// which the family's caps. What the picker checks and the row says.
    static func selected(for member: Member, family: Preset) -> Preset? {
        guard let own = member.notificationPrefs?.preset,
              ReminderRules.preset(member: member, household: family) == own else { return nil }
        return own
    }

    /// What Family shows: their own, or "Same as family (Balanced)".
    static func title(for member: Member, family: Preset) -> String {
        selected(for: member, family: family)?.title
            ?? String(localized: "Same as family (\(family.title))", comment: "A person's notifications follow the household's preset")
    }

    private static func rank(_ preset: Preset) -> Int { Preset.allCases.firstIndex(of: preset) ?? 0 }
}
