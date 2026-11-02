import Foundation

/// The day-of check-in on This Week (docs/spec.md → Notifications): "Home tonight?" for whoever's expected, and what a planner
/// needs to know when someone says no. No answer means home, so only a no is news. Pure, so the timing is tested.
enum DayOfCheckIn {
    /// A dinner someone's home for: a dish, or a quick pick the family has together. Everyone's on their own for Fend for
    /// yourselves, so nobody needs to know who's in.
    static func hasDinnerToAskAbout(mealID: UUID?, quickPick: QuickPick?) -> Bool {
        quickPick.map { $0 != .fendForYourselves } ?? (mealID != nil)
    }

    /// From the check-in time until dinner.
    static func isOpen(_ night: WeekNight, settings: HouseholdSettings, now: Date, calendar: Calendar) -> Bool {
        guard let start = DinnerPrompts.moment(settings.checkInTime, on: night.date, calendar: calendar),
              let dinner = DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date, calendar: calendar)
        else { return false }
        return now >= start && now < dinner
    }

    /// Tonight's night, if there's something to answer: a dinner to ask about, in an approved week, not logged, and the
    /// household home. A night with nobody asked isn't anyone's.
    private static func tonight(nights: [WeekNight], logs: [DinnerLog], settings: HouseholdSettings, isApproved: Bool, now: Date,
                                calendar: Calendar) -> WeekNight? {
        let today = CalendarDay(now, calendar: calendar)
        guard isApproved, !settings.isAway(on: today), let night = nights.first(where: { $0.date == today }),
              hasDinnerToAskAbout(mealID: night.mealID, quickPick: night.quickPick),
              !logs.contains(where: { $0.nightID == night.id }),
              isOpen(night, settings: settings, now: now, calendar: calendar) else { return nil }
        return night
    }

    /// The night to ask this person about. They've already answered if it's in `checkedIn`.
    static func asking(_ me: Member, nights: [WeekNight], logs: [DinnerLog], settings: HouseholdSettings, isApproved: Bool, now: Date,
                       calendar: Calendar) -> WeekNight? {
        guard !me.isAway(today: CalendarDay(now, calendar: calendar)),
              let night = tonight(nights: nights, logs: logs, settings: settings, isApproved: isApproved, now: now, calendar: calendar),
              night.attendance[me.id] == true, !night.checkedIn.contains(me.id) else { return nil }
        return night
    }

    /// The night this person said they'd miss, so they can take it back before dinner.
    static func saidNotHome(_ me: Member, nights: [WeekNight], logs: [DinnerLog], settings: HouseholdSettings, isApproved: Bool,
                            now: Date, calendar: Calendar) -> WeekNight? {
        guard let night = tonight(nights: nights, logs: logs, settings: settings, isApproved: isApproved, now: now, calendar: calendar),
              night.attendance[me.id] == false, night.checkedIn.contains(me.id) else { return nil }
        return night
    }

    /// Someone said they won't be home, as a planner hears it.
    struct Change: Identifiable, Equatable, Sendable {
        let night: WeekNight
        let member: Member
        /// There's a dish going ahead without them, so there'll be some left.
        let expectsLeftovers: Bool
        /// They were why this dish was picked.
        let offersSwap: Bool

        /// One per person per night: someone who changes their mind twice doesn't bring back a note that was dismissed.
        var id: String { "\(night.id.uuidString).\(member.id.uuidString)" }
    }

    /// Today's changes for a planner, until the day's over. Never their own answer.
    static func changes(nights: [WeekNight], members: [Member], me: UUID?, canPlan: Bool, today: CalendarDay,
                        dismissed: Set<String> = []) -> [Change] {
        guard canPlan, let night = nights.first(where: { $0.date == today }) else { return [] }
        return members.compactMap { member -> Change? in
            guard member.id != me, night.attendance[member.id] == false, night.checkedIn.contains(member.id) else { return nil }
            let change = Change(night: night, member: member,
                                expectsLeftovers: expectsLeftovers(night, without: member, members: members),
                                offersSwap: wasTheReason(member, for: night))
            return dismissed.contains(change.id) ? nil : change
        }
    }

    /// A dish being cooked (not a quick pick, leftovers, or the freezer) goes further with one fewer, if they'd have eaten it and
    /// someone's still home to. Someone who eats separately is on attendance but isn't eating this.
    private static func expectsLeftovers(_ night: WeekNight, without member: Member, members: [Member]) -> Bool {
        night.mealID != nil && night.quickPick == nil && night.leftoversFrom == nil && night.stashItemID == nil
            && !member.eatsSeparately
            && members.contains { !$0.eatsSeparately && night.attendance[$0.id] == true }
    }

    /// Whether the chip on the night names them: "Nora's favorite", "Nora's request". The chip is saved as words, in the language
    /// of whoever planned it, so another language reads as no and they just don't get the offer. Swap's still on the card.
    static func wasTheReason(_ member: Member, for night: WeekNight) -> Bool {
        guard let reason = night.reason else { return false }
        return reason == PlanReason.request(name: member.firstName).text || reason == PlanReason.favorite(name: member.firstName).text
    }
}
