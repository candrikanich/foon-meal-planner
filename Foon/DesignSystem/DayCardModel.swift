import Foundation

/// Everything a DayCard shows for one night. Plain values so This Week, planning, and previews
/// can build it from the cache, the algorithm's draft, or fixtures alike.
struct DayCardModel: Identifiable, Equatable, Sendable {
    enum Slot: Equatable, Sendable {
        case empty
        case meal(name: String, photoURL: URL?, reason: String?, sides: [String] = [])
        case quickPick(QuickPick)
        /// The household's away dates cover this night: nothing to plan.
        case away
    }

    struct Attendee: Equatable, Identifiable, Sendable {
        let memberID: UUID
        let firstName: String
        let avatar: String?
        let isHome: Bool

        var id: UUID { memberID }
    }

    enum Badge: Equatable, Hashable, Sendable {
        case allergy(String)
        case tradition(String)
        case request(from: String)
        case prep(String)
        case equipment(String)
        case foodRule(String)
        case startCooking(String)
        case doubled(String)
    }

    struct Cook: Equatable, Sendable {
        enum Tense: Equatable, Sendable {
            case willCook, cooked
        }

        let memberID: UUID
        let firstName: String
        let avatar: String?
        let isYou: Bool
        let tense: Tense

        init(member: Member, isYou: Bool, tense: Tense) {
            memberID = member.id
            firstName = member.firstName
            avatar = member.avatar
            self.isYou = isYou
            self.tense = tense
        }
    }

    struct JobLine: Equatable, Hashable, Sendable {
        let title: String
        let firstName: String
    }

    let date: CalendarDay
    var effort: NightEffort
    var slot: Slot
    var attendance: [Attendee]
    var badges: [Badge]
    var isLocked: Bool
    /// "Nora: keep everything separate", for people home that night.
    var servingNotes: [String] = []
    /// On a leftovers night that knows its dish: "From Monday's Chili".
    var leftoversNote: String? = nil
    /// Who's cooking, by what someone promised, or who did, by what was logged.
    var cook: Cook? = nil
    /// Dinner jobs for this night, when the household uses them.
    var jobs: [JobLine] = []

    var id: CalendarDay { date }
}

extension QuickPick {
    static let all: [QuickPick] = [.leftovers, .takeout, .eatOut, .fendForYourselves, .freezerRaid]

    var systemImage: String {
        switch self {
        case .leftovers: "takeoutbag.and.cup.and.straw"
        case .takeout: "bag"
        case .eatOut: "fork.knife.circle"
        case .fendForYourselves: "figure.wave"
        case .freezerRaid: "snowflake"
        }
    }
}

extension NightEffort {
    /// Tapping the effort chip cycles normal → rushed → full → event.
    var next: NightEffort {
        switch self {
        case .normal: .rushed
        case .rushed: .full
        case .full: .event
        case .event: .normal
        }
    }
}

/// The words on a DayCard, kept out of the view so they're testable and localizable.
enum DayCardText {
    static func dayLabel(for day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        if day == today { return String(localized: "Tonight") }
        if day == today.adding(days: 1, calendar: calendar) { return String(localized: "Tomorrow") }
        return day.date(in: calendar).formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))
    }

    /// "Dec 20", with the year if `today` is given and in a different one.
    static func dateLabel(for day: CalendarDay, calendar: Calendar = .current, relativeTo today: CalendarDay? = nil) -> String {
        let style = Date.FormatStyle(calendar: calendar).month(.abbreviated).day()
        return day.date(in: calendar).formatted(today.map { $0.year != day.year } == true ? style.year() : style)
    }

    static func effortLabel(_ effort: NightEffort) -> String {
        switch effort {
        case .normal: String(localized: "Normal")
        case .rushed: String(localized: "Rushed")
        case .full: String(localized: "Full evening")
        case .event: String(localized: "Event")
        }
    }

    static func quickPickLabel(_ pick: QuickPick) -> String {
        switch pick {
        case .leftovers: String(localized: "Leftovers")
        case .takeout: String(localized: "Takeout")
        case .eatOut: String(localized: "Eat out")
        case .fendForYourselves: String(localized: "Fend for yourselves")
        case .freezerRaid: String(localized: "Freezer raid")
        }
    }

    /// "with salad and garlic bread", or nil without sides.
    static func sidesLabel(_ sides: [String], locale: Locale = .current) -> String? {
        guard !sides.isEmpty else { return nil }
        let list = sides.formatted(.list(type: .and).locale(locale))
        return String(localized: "with \(list)", comment: "Side dishes after a meal name: a list of sides")
    }

    /// A big family's card shows six avatars and a "+N"; VoiceOver and night detail still list everyone. Whoever's
    /// away goes first, so the exception is never the one hidden.
    static func visibleAttendees(_ attendees: [DayCardModel.Attendee], limit: Int = 6)
        -> (visible: [DayCardModel.Attendee], hidden: Int) {
        guard attendees.count > limit else { return (attendees, 0) }
        let awayFirst = attendees.filter { !$0.isHome } + attendees.filter(\.isHome)
        return (Array(awayFirst.prefix(limit)), attendees.count - limit)
    }

    static func badgeLabel(_ badge: DayCardModel.Badge) -> String {
        switch badge {
        case .allergy(let text), .tradition(let text), .prep(let text), .equipment(let text), .foodRule(let text),
             .startCooking(let text), .doubled(let text): text
        case .request(let name): String(localized: "\(name)'s request", comment: "Day card badge: the member who asked for this dish")
        }
    }

    /// A claim is a promise, so it's about tonight; a log says what happened.
    static func cookLabel(_ cook: DayCardModel.Cook) -> String {
        switch (cook.tense, cook.isYou) {
        case (.willCook, true): String(localized: "You're cooking")
        case (.willCook, false): String(localized: "\(cook.firstName) is cooking")
        case (.cooked, true): String(localized: "You cooked")
        case (.cooked, false): String(localized: "\(cook.firstName) cooked")
        }
    }

    static func jobLabel(_ job: DayCardModel.JobLine) -> String {
        String(localized: "\(job.title): \(job.firstName)", comment: "A dinner job and whose turn it is")
    }

    /// One sentence VoiceOver reads for the whole card.
    static func accessibilitySummary(_ card: DayCardModel, today: CalendarDay, calendar: Calendar = .current) -> String {
        var parts = ["\(dayLabel(for: card.date, today: today, calendar: calendar)), \(dateLabel(for: card.date, calendar: calendar))"]
        switch card.slot {
        case .empty: parts.append(String(localized: "Nothing planned yet"))
        case .meal(let name, _, let reason, let sides):
            parts.append([name, reason, sidesLabel(sides)].compactMap { $0 }.joined(separator: ", "))
        case .quickPick(let pick): parts.append([quickPickLabel(pick), card.leftoversNote].compactMap { $0 }.joined(separator: ", "))
        case .away: parts.append(String(localized: "Away, no dinner to plan"))
        }
        if card.slot != .away { parts.append(effortLabel(card.effort)) }
        let home = card.attendance.filter(\.isHome).map(\.firstName)
        let away = card.attendance.filter { !$0.isHome }.map(\.firstName)
        if !home.isEmpty { parts.append(String(localized: "Home: \(home.joined(separator: ", "))")) }
        if !away.isEmpty { parts.append(String(localized: "Away: \(away.joined(separator: ", "))")) }
        parts.append(contentsOf: card.badges.map(badgeLabel))
        parts.append(contentsOf: card.servingNotes)
        if let cook = card.cook { parts.append(cookLabel(cook)) }
        parts.append(contentsOf: card.jobs.map(jobLabel))
        if card.isLocked { parts.append(String(localized: "Locked")) }
        return parts.joined(separator: ". ") + "."
    }
}
