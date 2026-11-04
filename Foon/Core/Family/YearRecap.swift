import Foundation

/// What `year_recap` says about one calendar year, by the household's day: how many dinners were logged, the stats
/// card's counts for the year, the most-made dishes, and who cooked and who tried something new (each in the order they
/// first did). The server picks; `YearRecap` decides what shows.
struct YearRecapFacts: Decodable, Equatable, Sendable {
    struct Dish: Decodable, Equatable, Sendable {
        let id: UUID
        let name: String
        let times: Int

        enum CodingKeys: String, CodingKey {
            case id = "meal_id"
            case name, times
        }
    }

    var logged = 0
    var stats = FamilyStats()
    var topDishes: [Dish] = []
    var cooks: [UUID] = []
    var tried: [UUID] = []

    enum CodingKeys: String, CodingKey {
        case logged, stats, cooks, tried
        case topDishes = "top_dishes"
    }
}

extension YearRecapFacts {
    /// Only `logged` is required, so a server that says less still gives a recap, just with fewer lines.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logged = try container.decode(Int.self, forKey: .logged)
        stats = try container.decodeIfPresent(FamilyStats.self, forKey: .stats) ?? FamilyStats()
        topDishes = try container.decodeIfPresent([Dish].self, forKey: .topDishes) ?? []
        cooks = try container.decodeIfPresent([UUID].self, forKey: .cooks) ?? []
        tried = try container.decodeIfPresent([UUID].self, forKey: .tried) ?? []
    }
}

/// "Your year in dinners" (docs/spec.md → Yearly recap), for everyone, kids included. Like the weekly recap, it thanks
/// whoever cooked and cheers whoever tried something new without counting or ranking anyone; the counts are about the
/// food.
struct YearRecap: Equatable, Sendable {
    /// Identified by its meal, since two dishes in a library can share a name.
    struct TopDish: Hashable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let times: Int

        var detail: String {
            String(localized: "Made \(times) times",
                   comment: "Yearly recap: how often a top dish was made that year; about the food")
        }
    }

    enum Line: Hashable, Sendable {
        case stat(FamilyStats.Line)
        /// Up to three, most made first.
        case topDishes([TopDish])
        /// First names, in the order they first cooked that year.
        case thanks([String])
        /// First names, in the order they first tried a dish new to them that year.
        case triedNew([String])
    }

    let year: Int
    let lines: [Line]
    let estimateNote: String?

    /// Nil for a year with no dinners logged (approved weeks only, which is the server's to judge).
    init?(year: Int, facts: YearRecapFacts, members: [Member]) {
        guard facts.logged > 0 else { return nil }
        let present = Dictionary(members.filter { $0.status != .removed }.map { ($0.id, $0.firstName) },
                                 uniquingKeysWith: { first, _ in first })
        let cooks = facts.cooks.compactMap { present[$0] }
        let tried = facts.tried.compactMap { present[$0] }
        let stats = facts.stats.lines
        func stat(_ matches: (FamilyStats.Line) -> Bool) -> Line? { stats.first(where: matches).map(Line.stat) }
        let candidates: [Line?] = [
            stat { if case .atTable = $0 { true } else { false } },
            facts.topDishes.isEmpty
                ? nil : .topDishes(facts.topDishes.map { TopDish(id: $0.id, name: $0.name, times: $0.times) }),
            cooks.isEmpty ? nil : .thanks(cooks),
            stat { if case .newDishes = $0 { true } else { false } },
            tried.isEmpty ? nil : .triedNew(tried),
            stat { if case .ideas = $0 { true } else { false } },
            stat { if case .timeSaved = $0 { true } else { false } }
        ]
        self.year = year
        lines = candidates.compactMap { $0 }
        estimateNote = facts.stats.estimateNote
    }

    /// The Family tab's year: this one so far, except in January's first week, which looks back on the one just ended.
    static func familyYear(today: CalendarDay) -> Int {
        today.month == 1 && today.day <= 7 ? today.year - 1 : today.year
    }

    /// This Week offers the recap from December 26 through January 7, about the year ending or just ended.
    static func cardYear(today: CalendarDay) -> Int? {
        switch (today.month, today.day) {
        case (12, 26...): today.year
        case (1, ...7): today.year - 1
        default: nil
        }
    }

    /// Where the server's range ends: today while the year is still going, so weeks approved ahead of time don't count
    /// before they happen; nil (December 31) for a year that's over.
    static func through(year: Int, today: CalendarDay) -> CalendarDay? {
        year >= today.year ? today : nil
    }

    /// "2026 so far" while the year is still going; "2025" once it's over.
    static func heading(year: Int, today: CalendarDay, locale: Locale = .current) -> String {
        let name = year.formatted(.number.grouping(.never).locale(locale))
        guard year >= today.year else { return name }
        return String(localized: "\(name) so far",
                      comment: "Yearly recap: heading while the year is still going; the argument is a year, like 2026")
    }

    /// Each device remembers which years' cards it closed: one per household and year.
    static func dismissalKey(household: UUID, year: Int) -> String {
        "\(household.uuidString).year.\(year)"
    }
}

extension YearRecap.Line {
    func title(locale: Locale = .current) -> String {
        switch self {
        case .stat(let line):
            return line.title
        case .topDishes:
            return String(localized: "The year's top dishes",
                          comment: "Yearly recap: heading over the dishes made most that year; the food, not the cook")
        case .thanks(let names):
            let people = Self.list(names, locale: locale)
            return String(localized: "Thanks for cooking this year, \(people).",
                          comment: "Yearly recap: thanks to the year's cooks; first names, never counted or ranked")
        case .triedNew(let names):
            let people = Self.list(names, locale: locale)
            return String(localized: "Tried something new this year: \(people).",
                          comment: "Yearly recap: who tried a dish new to them this year; first names, never counted")
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
        case .topDishes: "star"
        case .thanks: "hands.clap"
        case .triedNew: "sparkles"
        }
    }
}
