import Foundation

/// "This month" on the Family tab (docs/spec.md → Success metrics: shown to families): the load being shared, about the
/// food and never a cook by name. The counts come from `family_stats`; what shows and how it reads is decided here.
struct FamilyStats: Decodable, Equatable, Sendable {
    /// Approved nights with a dish or a quick pick.
    var dinners = 0
    /// Of those, the nights with a dish: what "someone else's idea" is out of.
    var dishes = 0
    /// Nights with a dish that a member (not a planner) asked for.
    var ideas = 0
    var cookedByOthers = 0
    var atTable = 0
    var newDishes = 0
    var weeksPlanned = 0

    /// What planning a week by hand is assumed to take. A default to revisit with founding families, and always shown
    /// as an estimate.
    static let minutesSavedPerWeekPlanned = 30

    enum CodingKeys: String, CodingKey {
        case dinners, dishes, ideas
        case cookedByOthers = "cooked_by_others"
        case atTable = "at_table"
        case newDishes = "new_dishes"
        case weeksPlanned = "weeks_planned"
    }

    enum Line: Hashable, Sendable {
        case dinners(Int)
        case ideas(Int, of: Int)
        case cookedByOthers(Int)
        case atTable(Int)
        case newDishes(Int)
        case timeSaved(minutes: Int)
    }

    var minutesSaved: Int { weeksPlanned * Self.minutesSavedPerWeekPlanned }

    /// Nothing planned yet this month: the card says so gently instead of a row of zeros.
    var isEmpty: Bool { dinners == 0 }

    /// Only what there's something to say about, in a fixed order.
    var lines: [Line] {
        guard !isEmpty else { return [] }
        let candidates: [(Bool, Line)] = [
            (true, .dinners(dinners)),
            (ideas > 0, .ideas(ideas, of: dishes)),
            (cookedByOthers > 0, .cookedByOthers(cookedByOthers)),
            (atTable > 0, .atTable(atTable)),
            (newDishes > 0, .newDishes(newDishes)),
            (weeksPlanned > 0, .timeSaved(minutes: minutesSaved))
        ]
        return candidates.filter(\.0).map(\.1)
    }

    /// Under the card whenever it shows time saved, so nobody takes the number for a measurement.
    var estimateNote: String? {
        guard lines.contains(.timeSaved(minutes: minutesSaved)) else { return nil }
        let perWeek = FamilyStats.Line.duration(minutes: Self.minutesSavedPerWeekPlanned)
        return String(localized: "An estimate: \(perWeek) for each week planned in Foon.",
                      comment: "Family stats: footnote under the planning time saved; the argument is a duration like \"30 minutes\"")
    }

    /// The first and last day the month's stats cover: the 1st through today.
    static func monthToDate(today: CalendarDay) -> (from: CalendarDay, to: CalendarDay) {
        (CalendarDay(year: today.year, month: today.month, day: 1), today)
    }
}

extension FamilyStats.Line {
    var title: String {
        switch self {
        case .dinners(let count):
            count == 1
                ? String(localized: "1 dinner planned together", comment: "Family stats: dinners planned this month")
                : String(localized: "\(count) dinners planned together", comment: "Family stats: dinners planned this month")
        case .ideas(let count, let dishes):
            if dishes == 1 {
                String(localized: "1 dinner was someone else's idea",
                       comment: "Family stats: the month's one dish was asked for by someone other than a planner")
            } else if count == 1 {
                String(localized: "1 of \(dishes) dinners was someone else's idea",
                       comment: "Family stats: dishes asked for by someone other than a planner")
            } else {
                String(localized: "\(count) of \(dishes) dinners were someone else's idea",
                       comment: "Family stats: dishes asked for by someone other than a planner")
            }
        case .cookedByOthers(let count):
            count == 1
                ? String(localized: "1 night cooked by someone other than the usual cook",
                         comment: "Family stats: dinners cooked by someone new to the stove")
                : String(localized: "\(count) nights cooked by someone other than the usual cook",
                         comment: "Family stats: dinners cooked by someone new to the stove")
        case .atTable(let count):
            count == 1
                ? String(localized: "1 family dinner at the table", comment: "Family stats: dinners eaten at home")
                : String(localized: "\(count) family dinners at the table", comment: "Family stats: dinners eaten at home")
        case .newDishes(let count):
            count == 1
                ? String(localized: "1 new dish tried", comment: "Family stats: dishes the family had for the first time")
                : String(localized: "\(count) new dishes tried", comment: "Family stats: dishes the family had for the first time")
        case .timeSaved(let minutes):
            String(localized: "About \(Self.duration(minutes: minutes)) of planning saved",
                   comment: "Family stats: estimated planning time saved; the argument is a duration like \"1 hour, 30 minutes\"")
        }
    }

    var systemImage: String {
        switch self {
        case .dinners: "calendar"
        case .ideas: "lightbulb"
        case .cookedByOthers: "frying.pan"
        case .atTable: "fork.knife"
        case .newDishes: "sparkles"
        case .timeSaved: "clock"
        }
    }

    /// "30 minutes", "2 hours", "1 hour, 30 minutes".
    static func duration(minutes: Int, locale: Locale = .current) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .wide)
        style.locale = locale
        return Duration.seconds(minutes * 60).formatted(style)
    }
}
