import Foundation

/// Cook credit (docs/spec.md → After-dinner loop): who cooked this month, and the thanks they got. Never a rating of
/// the cook. Pure, from the dinner logs.
enum CookCredit {
    struct Tally: Identifiable, Hashable, Sendable {
        let memberID: UUID
        let dinners: Int
        let thanks: Int
        var id: UUID { memberID }

        var dinnersTitle: String {
            dinners == 1 ? String(localized: "1 dinner") : String(localized: "\(dinners) dinners")
        }

        var thanksTitle: String {
            thanks == 1 ? String(localized: "1 thank-you") : String(localized: "\(thanks) thank-yous")
        }
    }

    /// Everyone who cooked a dish logged this month (quick picks aren't cooking), in no ranked order: the view lists
    /// them in family order, so it's credit, not a leaderboard.
    static func thisMonth(logs: [DinnerLog], thanks: [ChefThanks], today: CalendarDay) -> [Tally] {
        let month = logs.filter { $0.mealID != nil && $0.date.year == today.year && $0.date.month == today.month }
        let thanked = Dictionary(grouping: thanks, by: \.logID).mapValues(\.count)
        let byCook = Dictionary(grouping: month.filter { $0.cookedByMemberID != nil }, by: { $0.cookedByMemberID! })
        return byCook.map { cook, logs in
            Tally(memberID: cook, dinners: logs.count, thanks: logs.reduce(0) { $0 + (thanked[$1.id] ?? 0) })
        }
        .sorted { $0.memberID.uuidString < $1.memberID.uuidString }
    }

    /// Dinners whose card is still open and someone is down as the cook: a Thanks, chef for everyone else once who cooked
    /// is settled (a thanks locks the cook, and a claim's default is only a guess), and from the start for the cook, who
    /// can say "That wasn't me".
    static func recent(nights: [WeekNight], logs: [DinnerLog], me: UUID? = nil, defaultDinnerTime: String, now: Date,
                       calendar: Calendar) -> [DinnerLog] {
        let nights = Dictionary(nights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return logs.filter { log in
            guard log.cookedByMemberID != nil, log.mealID != nil, let night = nights[log.nightID],
                  log.isSettled || log.cookedByMemberID == me else { return false }
            return DinnerPrompts.isOpen(night, defaultDinnerTime: defaultDinnerTime, now: now, calendar: calendar)
        }
    }

    /// Who can take someone off as a dinner's cook from the app: them, anyone for a profile nobody has claimed, or a
    /// planner. Not once they've been thanked: the server keeps a thanked cook.
    static func canTakeOffCook(_ log: DinnerLog, thanks: [ChefThanks], me: Member?, canPlan: Bool, members: [Member]) -> Bool {
        guard let cook = log.cookedByMemberID, log.mealID != nil, thanks.isEmpty else { return false }
        return canPlan || cook == me?.id || members.first { $0.id == cook }?.userID == nil
    }
}
