import Foundation

/// What `engagement` counts for one member over a range of household days (docs/spec.md → Keeping kids engaged
/// without nagging). Only what's already stored: requests, me-toos, ratings, check-in answers still on record, claims
/// not taken back, and logged dishes they cooked.
struct EngagementCounts: Equatable, Sendable {
    let memberID: UUID
    var ideas = 0
    var meToos = 0
    var rated = 0
    var checkIns = 0
    var claimed = 0
    /// The nights, in order, of the dishes they cooked.
    var cooked: [CalendarDay] = []
    /// The latest day they asked for something or said me too, up to the range's end, ever.
    var lastIdeaOn: CalendarDay?
    var joinedOn: CalendarDay?

    /// Nothing to say: nothing sent, rated, answered, claimed, or cooked.
    var isEmpty: Bool { ideas + meToos + rated + checkIns + claimed == 0 && cooked.isEmpty }
}

extension EngagementCounts: Decodable {
    enum CodingKeys: String, CodingKey {
        case ideas, rated, claimed, cooked
        case memberID = "member_id"
        case meToos = "me_toos"
        case checkIns = "check_ins"
        case lastIdeaOn = "last_idea_on"
        case joinedOn = "joined_on"
    }

    /// Only the member is required, so a server that says less still gives a row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try container.decode(UUID.self, forKey: .memberID)
        ideas = try container.decodeIfPresent(Int.self, forKey: .ideas) ?? 0
        meToos = try container.decodeIfPresent(Int.self, forKey: .meToos) ?? 0
        rated = try container.decodeIfPresent(Int.self, forKey: .rated) ?? 0
        checkIns = try container.decodeIfPresent(Int.self, forKey: .checkIns) ?? 0
        claimed = try container.decodeIfPresent(Int.self, forKey: .claimed) ?? 0
        cooked = try container.decodeIfPresent([CalendarDay].self, forKey: .cooked) ?? []
        lastIdeaOn = try container.decodeIfPresent(CalendarDay.self, forKey: .lastIdeaOn)
        joinedOn = try container.decodeIfPresent(CalendarDay.self, forKey: .joinedOn)
    }
}

struct EngagementFacts: Decodable, Equatable, Sendable {
    var members: [EngagementCounts] = []

    enum CodingKeys: String, CodingKey { case members }

    init(members: [EngagementCounts] = []) {
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decodeIfPresent([EngagementCounts].self, forKey: .members) ?? []
    }
}

/// "Who's pitching in" on the Family tab, for planners: one warm line per person of what they did, in family order.
/// Never sorted by counts, never totalled or compared, and no streaks. Someone quiet gets at most one note, worded as a
/// nudge for the parent rather than a mark against them.
enum Engagement {
    struct Window: Equatable, Sendable {
        let from: CalendarDay
        let to: CalendarDay
    }

    struct Row: Identifiable, Equatable, Sendable {
        let member: Member
        let thisWeek: String?
        let lately: String?
        let note: String?

        var id: UUID { member.id }
    }

    /// "Lately": the four weeks ending today.
    static let latelyDays = 28
    /// How long without an idea before the note, and how long someone's been in the family before any note.
    static let quietDays = 21

    /// This week is the household's plan week containing today; lately is the 4 weeks ending today.
    static func windows(today: CalendarDay, weekStart: Int, calendar: Calendar) -> (thisWeek: Window, lately: Window) {
        let start = WeekMath.start(of: today, weekStart: weekStart, calendar: calendar)
        return (Window(from: start, to: start.adding(days: 6, calendar: calendar)),
                Window(from: today.adding(days: -(latelyDays - 1), calendar: calendar), to: today))
    }

    /// Members not removed, in the order given (family order), that the server counted and there's something to say
    /// about.
    static func rows(members: [Member], thisWeek: EngagementFacts, lately: EngagementFacts, today: CalendarDay,
                     calendar: Calendar) -> [Row] {
        let week = Dictionary(thisWeek.members.map { ($0.memberID, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = Dictionary(lately.members.map { ($0.memberID, $0) }, uniquingKeysWith: { first, _ in first })
        return members.filter { $0.status != .removed }.compactMap { member in
            guard let counts = recent[member.id] else { return nil }
            let weekCounts = week[member.id]
            let weekLine = weekCounts.flatMap { summary($0, namingDays: true, calendar: calendar) }
            let sameAsWeek = weekCounts.map { sameCounts($0, counts) } ?? false
            let latelyLine = sameAsWeek ? nil : summary(counts, namingDays: false, calendar: calendar)
            let row = Row(
                member: member,
                thisWeek: weekLine.map {
                    String(localized: "This week: \($0)",
                           comment: "Who's pitching in: what someone did this plan week, like \"sent 2 ideas\"")
                },
                lately: latelyLine.map {
                    String(localized: "Last 4 weeks: \($0)",
                           comment: "Who's pitching in: what someone did in the 4 weeks ending today")
                },
                note: note(for: member, counts: counts, today: today, calendar: calendar)
            )
            return row.thisWeek == nil && row.lately == nil && row.note == nil ? nil : row
        }
    }

    /// "sent 2 ideas · rated 5 dinners · cooked Tuesday", leaving out anything at zero; nil when there's nothing. With
    /// `namingDays`, one dinner cooked is named by its weekday.
    static func summary(_ counts: EngagementCounts, namingDays: Bool, calendar: Calendar) -> String? {
        var parts: [String] = []
        if counts.ideas > 0 {
            parts.append(String(localized: "sent \(counts.ideas) ideas",
                                comment: "Who's pitching in: requests someone sent; joined with others by \" · \""))
        }
        if counts.meToos > 0 {
            parts.append(String(localized: "said me too to \(counts.meToos) ideas",
                                comment: "Who's pitching in: someone else's requests this person backed with me too"))
        }
        if counts.rated > 0 {
            parts.append(String(localized: "rated \(counts.rated) dinners",
                                comment: "Who's pitching in: dinners someone rated; about the food"))
        }
        if counts.checkIns > 0 {
            parts.append(String(localized: "answered \(counts.checkIns) check-ins",
                                comment: "Who's pitching in: \"Home tonight?\" check-ins someone answered"))
        }
        if counts.claimed > 0 {
            parts.append(String(localized: "claimed \(counts.claimed) nights",
                                comment: "Who's pitching in: nights someone offered to cook"))
        }
        if let only = counts.cooked.first, counts.cooked.count == 1, namingDays {
            let weekday = WeekMath.Weekday(iso: WeekMath.isoWeekday(of: only, calendar: calendar))
                .name(calendar: calendar)
            parts.append(String(localized: "cooked \(weekday)",
                                comment: "Who's pitching in: the one night this week someone cooked; a weekday"))
        } else if !counts.cooked.isEmpty {
            parts.append(String(localized: "cooked \(counts.cooked.count) dinners",
                                comment: "Who's pitching in: logged dishes someone cooked"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// At most one note, and only for someone who's around to ask: not a planner (they plan), not away, not someone who
    /// eats separately, and in the family at least 3 weeks.
    static func note(for member: Member, counts: EngagementCounts, today: CalendarDay, calendar: Calendar) -> String? {
        let cutoff = today.adding(days: -(quietDays - 1), calendar: calendar)
        guard member.role == .member, member.status == .active, !member.eatsSeparately,
              (counts.joinedOn ?? cutoff) <= cutoff else { return nil }
        if counts.isEmpty {
            return String(localized: "No ideas from \(member.firstName) lately. Maybe ask what sounds good?",
                          comment: "Who's pitching in: a quiet nudge for a parent; nothing from them in 4 weeks")
        }
        if counts.lastIdeaOn.map({ $0 < cutoff }) ?? true {
            return String(localized: "No ideas from \(member.firstName) in 3 weeks.",
                          comment: "Who's pitching in: a quiet nudge for a parent; someone who's done other things")
        }
        return nil
    }

    private static func sameCounts(_ lhs: EngagementCounts, _ rhs: EngagementCounts) -> Bool {
        (lhs.ideas, lhs.meToos, lhs.rated, lhs.checkIns, lhs.claimed, lhs.cooked)
            == (rhs.ideas, rhs.meToos, rhs.rated, rhs.checkIns, rhs.claimed, rhs.cooked)
    }
}
