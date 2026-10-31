import Foundation

/// What one person's device may send: which reminders, how many a week, and when not (docs/spec.md → Notifications). Worked
/// out from the household's preset and their own prefs; #47's per-member overrides change it here and nowhere else.
struct ReminderRules: Equatable, Sendable {
    /// A stretch of the household's clock: minutes after midnight, running past midnight when `end` is before `start`.
    struct Window: Equatable, Sendable {
        let start: Int
        let end: Int
        /// ISO weekdays it applies on, where it starts; nil for every day.
        var weekdays: Set<Int>?

        /// Tonight's or this morning's run of the window, if `date` is inside one.
        func run(containing date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
            let day = calendar.startOfDay(for: date)
            for offset in [0, -1] {
                guard let opened = calendar.date(byAdding: .day, value: offset, to: day),
                      weekdays?.contains(Self.isoWeekday(opened, calendar)) ?? true,
                      let from = Self.moment(start, on: opened, calendar),
                      let closes = end > start ? opened : calendar.date(byAdding: .day, value: 1, to: opened),
                      let to = Self.moment(end, on: closes, calendar),
                      from <= date, date < to else { continue }
                return (from, to)
            }
            return nil
        }

        private static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
            let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
            return weekday == 1 ? 7 : weekday - 1
        }

        private static func moment(_ minute: Int, on day: Date, _ calendar: Calendar) -> Date? {
            calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
        }
    }

    /// 9pm to 7am for everyone.
    static let quietHours = Window(start: 21 * 60, end: 7 * 60)
    /// Kids' devices, 8am to 3pm on school days. It doesn't know about holidays: a quiet day off costs nothing.
    static let schoolHours = Window(start: 8 * 60, end: 15 * 60, weekdays: [1, 2, 3, 4, 5])

    var kinds: Set<ReminderKind>
    /// The most sent to this person in one of the household's weeks, counting what's gone already.
    var weeklyBudget: Int
    /// Engaged's one follow-up on Time to plan and prep reminders.
    var followsUp: Bool
    var quietWindows: [Window]

    init(member: Member, settings: HouseholdSettings) {
        let preset = Self.preset(member: member, household: settings.notificationPreset)
        let isKid = member.ageGroup == .kid
        switch preset {
        case .light:
            kinds = [.timeToPlan, .prep]
            weeklyBudget = isKid ? 2 : 8
        case .balanced:
            kinds = [.timeToPlan, .prep, .afterDinner]
            weeklyBudget = isKid ? 5 : 12
        case .engaged:
            kinds = [.timeToPlan, .prep, .afterDinner]
            weeklyBudget = isKid ? 6 : 16
        }
        followsUp = preset == .engaged
        quietWindows = isKid ? [Self.quietHours, Self.schoolHours] : [Self.quietHours]
    }

    /// Their own, if they've set one. Kids can only turn theirs down.
    static func preset(member: Member, household: HouseholdSettings.NotificationPreset) -> HouseholdSettings.NotificationPreset {
        guard let own = member.notificationPrefs?.preset else { return household }
        guard member.ageGroup == .kid else { return own }
        let order = HouseholdSettings.NotificationPreset.allCases
        return (order.firstIndex(of: own) ?? 0) < (order.firstIndex(of: household) ?? 0) ? own : household
    }

    func window(containing date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        for window in quietWindows {
            if let run = window.run(containing: date, calendar: calendar) { return run }
        }
        return nil
    }
}
