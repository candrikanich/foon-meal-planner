import Foundation

/// A helper task for a night (docs/spec.md → Dinner jobs). The server knows the same keys.
enum DinnerJob: String, CaseIterable, Sendable {
    case setTable = "set_table"
    case clearTable = "clear_table"
    case dishes

    var title: String {
        switch self {
        case .setTable: String(localized: "Set the table", comment: "A dinner job")
        case .clearTable: String(localized: "Clear the table", comment: "A dinner job")
        case .dishes: String(localized: "Do the dishes", comment: "A dinner job")
        }
    }
}

/// `households.settings.dinner_jobs`. Off until a planner picks a job. Lists who's left out, not who's in, so someone new
/// joins the rotation without anyone having to remember. A job from a newer app is ignored here and kept on the server.
struct DinnerJobSettings: Equatable, Sendable, Decodable {
    var jobs: Set<DinnerJob> = []
    var leftOut: Set<UUID> = []

    init(jobs: Set<DinnerJob> = [], leftOut: Set<UUID> = []) {
        self.jobs = jobs
        self.leftOut = leftOut
    }

    private enum CodingKeys: String, CodingKey {
        case jobs
        case leftOut = "left_out"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jobs = ((try? container.decodeIfPresent([String].self, forKey: .jobs)) ?? nil) ?? []
        self.jobs = Set(jobs.compactMap(DinnerJob.init(rawValue:)))
        let leftOut = ((try? container.decodeIfPresent([String].self, forKey: .leftOut)) ?? nil) ?? []
        self.leftOut = Set(leftOut.compactMap(UUID.init(uuidString:)))
    }
}

/// Who does what each night. Nothing is stored: it's a pure function of the week, so every phone shows the same thing, and
/// there's nothing to check off, miss, or keep score of. Skipping one is between you and whoever you trade with.
enum DinnerJobs {
    struct Assignment: Equatable, Sendable {
        let job: DinnerJob
        let memberID: UUID
    }

    /// Who takes turns: the family, minus who eats separately and who a planner left out. By id, so it doesn't depend on
    /// the order a phone has them in.
    static func rotation(members: [Member], settings: DinnerJobSettings) -> [UUID] {
        members.filter { $0.status != .removed && !$0.eatsSeparately && !settings.leftOut.contains($0.id) }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// A night with something to set the table for. Not when you're out or fending for yourselves, not an empty night (it
    /// would say something that isn't known yet), and not an away night.
    static func hasJobs(_ night: WeekNight, away: [AwayDates], today: CalendarDay) -> Bool {
        guard !night.readsAway(in: away, today: today) else { return false }
        if night.mealID != nil { return true }
        switch night.quickPick {
        case .leftovers, .takeout, .freezerRaid: return true
        case .eatOut, .fendForYourselves, nil: return false
        }
    }

    /// Goes through the week in order, and gives each job to whoever home has done least this week, then that job least,
    /// so people home the same nights stay even, and someone back from being out takes the next turn. Who starts moves on
    /// each week. The night's cook has nothing to do, and nobody gets two jobs in a night. With too few people, the job done
    /// least this week goes first, so it's a different job that doesn't show each night, not always the same one.
    static func assign(nights: [WeekNight], settings: DinnerJobSettings, members: [Member], cooks: [UUID: UUID],
                       away: [AwayDates], today: CalendarDay) -> [UUID: [Assignment]] {
        let jobs = DinnerJob.allCases.filter(settings.jobs.contains)
        let sorted = nights.sorted { $0.date < $1.date }
        let people = rotation(members: members, settings: settings)
        guard !jobs.isEmpty, !people.isEmpty, let first = sorted.first else { return [:] }

        let shift = weekNumber(first.date) % people.count
        let order = Array(people[shift...] + people[..<shift])
        var total: [UUID: Int] = [:]
        var perJob: [DinnerJob: [UUID: Int]] = [:]
        var jobTurns: [DinnerJob: Int] = [:]
        var assigned: [UUID: [Assignment]] = [:]

        for night in sorted where hasJobs(night, away: away, today: today) {
            var free = order.filter { night.attendance[$0] == true && $0 != cooks[night.id] }
            let leastDoneFirst = jobs.enumerated()
                .sorted { (jobTurns[$0.element, default: 0], $0.offset) < (jobTurns[$1.element, default: 0], $1.offset) }
                .map(\.element)
            var tonight: [Assignment] = []
            for job in leastDoneFirst {
                let next = free.enumerated().min { lhs, rhs in
                    let left = (total[lhs.element, default: 0], perJob[job]?[lhs.element] ?? 0, lhs.offset)
                    let right = (total[rhs.element, default: 0], perJob[job]?[rhs.element] ?? 0, rhs.offset)
                    return left < right
                }
                guard let next else { break }
                free.remove(at: next.offset)
                total[next.element, default: 0] += 1
                perJob[job, default: [:]][next.element, default: 0] += 1
                jobTurns[job, default: 0] += 1
                tonight.append(Assignment(job: job, memberID: next.element))
            }
            if !tonight.isEmpty {
                assigned[night.id] = jobs.compactMap { job in tonight.first { $0.job == job } }
            }
        }
        return assigned
    }

    /// The week's jobs, for the card and the night's detail.
    static func forWeek(nights: [WeekNight], settings: DinnerJobSettings, members: [Member], claims: [NightClaim],
                        away: [AwayDates], today: CalendarDay) -> [UUID: [Assignment]] {
        guard !settings.jobs.isEmpty else { return [:] }
        let cooks = NightClaims.cooks(nights: nights, claims: claims, members: members, away: away, today: today)
        return assign(nights: nights, settings: settings, members: members, cooks: cooks, away: away, today: today)
    }

    /// What a card says: nights ahead only, since a job from last night is nobody's business now.
    static func lines(for night: WeekNight, in assigned: [UUID: [Assignment]], members: [Member],
                      today: CalendarDay) -> [DayCardModel.JobLine] {
        guard night.date >= today else { return [] }
        return (assigned[night.id] ?? []).compactMap { assignment in
            members.first { $0.id == assignment.memberID }.map {
                DayCardModel.JobLine(title: assignment.job.title, firstName: $0.firstName)
            }
        }
    }

    /// Weeks since 1970, whatever device or time zone is asking.
    private static func weekNumber(_ day: CalendarDay) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return Int(day.date(in: utc).timeIntervalSince1970 / 86_400) / 7
    }
}
