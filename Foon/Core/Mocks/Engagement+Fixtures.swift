import Foundation

extension EngagementFacts {
    /// Who's pitching in, for previews: a week (seven days or fewer) or the four weeks ending `to`. Ann and Ben cook,
    /// Nora rates and checks in but hasn't asked for anything in a while, and Owen is away at camp.
    static func sample(for members: [Member] = Member.sampleFamily, from: CalendarDay, to: CalendarDay)
        -> EngagementFacts {
        let isWeek = to < from.adding(days: 7)
        let joined = from.adding(days: -60)
        let counts: [EngagementCounts] = members.enumerated().map { index, member in
            switch index {
            case 0:
                EngagementCounts(memberID: member.id, rated: isWeek ? 2 : 9, cooked: isWeek ? [from] : [from, to],
                                 lastIdeaOn: to, joinedOn: joined)
            case 1:
                EngagementCounts(memberID: member.id, ideas: isWeek ? 1 : 3, rated: isWeek ? 3 : 11, claimed: 1,
                                 cooked: [to], lastIdeaOn: to, joinedOn: joined)
            case 4:
                EngagementCounts(memberID: member.id, meToos: isWeek ? 0 : 1, rated: isWeek ? 2 : 7,
                                 checkIns: isWeek ? 1 : 4, lastIdeaOn: from.adding(days: -40), joinedOn: joined)
            default:
                EngagementCounts(memberID: member.id, joinedOn: joined)
            }
        }
        return EngagementFacts(members: counts)
    }
}

extension Engagement.Row {
    /// The section's rows for previews, including someone with nothing lately.
    static var samples: [Engagement.Row] {
        let members = Member.sampleFamily
            + [.fixture(firstName: "Milo", avatar: "🐸", ageGroup: .kid)]
        let today = CalendarDay(year: 2026, month: 11, day: 4)
        let windows = Engagement.windows(today: today, weekStart: 7, calendar: .current)
        return Engagement.rows(
            members: members,
            thisWeek: .sample(for: members, from: windows.thisWeek.from, to: windows.thisWeek.to),
            lately: .sample(for: members, from: windows.lately.from, to: windows.lately.to),
            today: today, calendar: .current
        )
    }
}
