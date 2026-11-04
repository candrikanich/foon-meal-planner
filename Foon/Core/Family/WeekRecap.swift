import Foundation

/// What `week_recap` says about one week: how many dinners were logged, who cooked and who tried a new dish (each in
/// the order they first did), the dish people liked most, and a favorite not had in a while. The server picks;
/// `WeekRecap` decides what shows.
struct WeekRecapFacts: Decodable, Equatable, Sendable {
    struct Dish: Decodable, Equatable, Sendable {
        let id: UUID
        let name: String

        enum CodingKeys: String, CodingKey {
            case id = "meal_id"
            case name
        }
    }

    var logged = 0
    var cooks: [UUID] = []
    var tried: [UUID] = []
    var topDish: Dish?
    var forgottenFavorite: Dish?

    enum CodingKeys: String, CodingKey {
        case logged, cooks, tried
        case topDish = "top_dish"
        case forgottenFavorite = "forgotten_favorite"
    }
}

extension WeekRecapFacts {
    /// `tried` came later (#65): a server without it yet still gives a recap, just without that line.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logged = try container.decode(Int.self, forKey: .logged)
        cooks = try container.decode([UUID].self, forKey: .cooks)
        tried = try container.decodeIfPresent([UUID].self, forKey: .tried) ?? []
        topDish = try container.decodeIfPresent(Dish.self, forKey: .topDish)
        forgottenFavorite = try container.decodeIfPresent(Dish.self, forKey: .forgottenFavorite)
    }
}

/// The weekly recap on This Week (docs/spec.md → Weekly recap): last week's dinners, for everyone, kids included. It
/// thanks whoever cooked and cheers whoever tried something new, without counting or ranking anyone, and the rest is
/// about the food.
struct WeekRecap: Equatable, Sendable {
    enum Line: Hashable, Sendable {
        case stat(FamilyStats.Line)
        /// First names, in the order they first cooked that week.
        case thanks([String])
        /// First names, in the order they first tried a dish new to them that week.
        case triedNew([String])
        case topDish(String)
        case forgottenFavorite(String)
    }

    /// How long the card stays after the week ends.
    static let daysShown = 3

    let weekStart: CalendarDay
    let lines: [Line]
    let estimateNote: String?

    /// The week that ended in the last `daysShown` days, if there is one.
    static func week(today: CalendarDay, weekStart: Int,
                     calendar: Calendar) -> (start: CalendarDay, end: CalendarDay)? {
        let thisWeek = WeekMath.start(of: today, weekStart: weekStart, calendar: calendar)
        let start = thisWeek.adding(days: -7, calendar: calendar)
        let end = start.adding(days: 6, calendar: calendar)
        guard today <= end.adding(days: daysShown, calendar: calendar) else { return nil }
        return (start, end)
    }

    /// Nil when there's nothing to look back on: no dinners logged (or the week wasn't approved, which means the same
    /// to the server), none planned together, or the household was away all week.
    init?(weekStart: CalendarDay, facts: WeekRecapFacts, stats: FamilyStats, members: [Member],
          settings: HouseholdSettings, calendar: Calendar) {
        let days = (0..<7).map { weekStart.adding(days: $0, calendar: calendar) }
        guard facts.logged > 0, !stats.isEmpty, !days.allSatisfy(settings.isAway(on:)) else { return nil }
        let present = Dictionary(members.filter { $0.status != .removed }.map { ($0.id, $0.firstName) },
                                 uniquingKeysWith: { first, _ in first })
        let cooks = facts.cooks.compactMap { present[$0] }
        let tried = facts.tried.compactMap { present[$0] }
        let statLines = stats.lines.map(Line.stat)
        let middle: [Line?] = [
            cooks.isEmpty ? nil : .thanks(cooks),
            tried.isEmpty ? nil : .triedNew(tried),
            facts.topDish.map { .topDish($0.name) },
            facts.forgottenFavorite.map { .forgottenFavorite($0.name) }
        ]
        self.weekStart = weekStart
        lines = Array(statLines.prefix(1)) + middle.compactMap { $0 } + statLines.dropFirst()
        estimateNote = stats.estimateNote
    }

    /// Each device remembers which recaps it closed: one per household and week.
    static func dismissalKey(household: UUID, week: CalendarDay) -> String {
        "\(household.uuidString).\(week.isoString)"
    }
}

extension WeekRecap.Line {
    func title(locale: Locale = .current) -> String {
        switch self {
        case .stat(let line):
            return line.title
        case .thanks(let names):
            let people = Self.list(names, locale: locale)
            return String(localized: "Thanks for cooking, \(people).",
                          comment: "Weekly recap: thanks to last week's cooks; first names, never counted or ranked")
        case .triedNew(let names):
            let people = Self.list(names, locale: locale)
            return String(localized: "Tried something new: \(people).",
                          comment: "Weekly recap: who tried a dish new to them last week; first names, never counted")
        case .topDish(let name):
            return String(localized: "The week's hit: \(name)",
                          comment: "Weekly recap: the dish the family liked most last week; the food, not the cook")
        case .forgottenFavorite(let name):
            return String(localized: "A favorite you haven't had in a while: \(name)",
                          comment: "Weekly recap: a family favorite not made in six weeks or more")
        }
    }

    private static func list(_ names: [String], locale: Locale) -> String {
        var style: ListFormatStyle<StringStyle, [String]> = .list(type: .and, width: .standard)
        style.locale = locale
        return names.formatted(style)
    }

    var systemImage: String {
        switch self {
        case .stat(let line): line.systemImage
        case .thanks: "hands.clap"
        case .triedNew: "sparkles"
        case .topDish: "star"
        case .forgottenFavorite: "heart"
        }
    }
}
