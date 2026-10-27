import Foundation

/// One night as Build my week sees it: what's already decided and who's expected home.
struct PlanningNight: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: CalendarDay
    var effort: NightEffort
    /// Member id → expected home, as on `WeekNight`.
    var attendance: [UUID: Bool]
    /// Pinned by the planner: kept exactly as it is.
    var locked: Bool
    var mealID: UUID?
    var quickPick: QuickPick?

    var home: Set<UUID> { Set(attendance.filter(\.value).keys) }
    /// Everyone with a row is home. A night with no rows (a household of nobody yet) counts as full.
    var isFullAttendance: Bool { attendance.values.allSatisfy { $0 } }
    /// Everyone's out. A night with no rows isn't: it just hasn't been laid out.
    var isNobodyHome: Bool { !attendance.isEmpty && home.isEmpty }

    init(id: UUID, date: CalendarDay, effort: NightEffort = .normal, attendance: [UUID: Bool] = [:],
         locked: Bool = false, mealID: UUID? = nil, quickPick: QuickPick? = nil) {
        (self.id, self.date, self.effort, self.attendance) = (id, date, effort, attendance)
        (self.locked, self.mealID, self.quickPick) = (locked, mealID, quickPick)
    }

    init(_ night: WeekNight) {
        self.init(id: night.id, date: night.date, effort: night.effort, attendance: night.attendance,
                  locked: night.locked, mealID: night.mealID, quickPick: night.quickPick)
    }
}

/// A dish someone asked for on a specific night ("steak Friday, my night off"). Lands on its night like a pin.
struct DatedRequest: Equatable, Sendable {
    let mealID: UUID
    let date: CalendarDay
    let requesterID: UUID
}

/// A standing tradition (Taco Tuesday): a meal or quick pick on an ISO weekday (1 = Monday), from `traditions`.
struct Tradition: Equatable, Sendable, Decodable {
    let weekday: Int
    let pick: NightPick
    /// The chip on the night ("Taco Tuesday"); "Tradition" without one.
    let name: String?

    init(weekday: Int, pick: NightPick, name: String?) {
        (self.weekday, self.pick, self.name) = (weekday, pick, name)
    }

    /// Trimmed and capped at 40 code points, as Postgres counts, without splitting a character. Blank is none.
    static func cleanedName(_ typed: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.unicodeScalars.count > 40 { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private enum CodingKeys: String, CodingKey {
        case weekday, name
        case mealID = "meal_id"
        case quickPick = "quick_pick"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekday = try container.decode(Int.self, forKey: .weekday)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let mealID = try container.decodeIfPresent(UUID.self, forKey: .mealID) {
            pick = .meal(mealID)
        } else {
            pick = .quickPick(try container.decode(QuickPick.self, forKey: .quickPick))
        }
    }
}

/// Everything Build my week reads. Inputs that arrive with later milestones (reactions, snoozes, favorites,
/// requests, stock) default to empty, so filling them in never changes the call site.
struct PlanningInputs: Equatable, Sendable {
    /// The nights to fill, in any order; the draft comes back in date order.
    var nights: [PlanningNight]
    /// The household library. The catalog is never drawn from: a family only gets dishes they chose.
    var meals: [LibraryMeal]
    var history: [MealHistory] = []
    var settings = HouseholdSettings()
    /// First names for reason chips ("Nora's favorite").
    var memberNames: [UUID: String] = [:]
    /// Meal id → member id → "not for me" count. One means skip nights that member is home. Two or more
    /// retires the dish, which reaches the planner as `MealStatus.retired`, so status stays the source of truth.
    var notForMe: [UUID: [UUID: Int]] = [:]
    var snoozedMealIDs: Set<UUID> = []
    /// Member id → meal ids they marked favorite.
    var favorites: [UUID: Set<UUID>] = [:]
    /// Meal id → thumbs-up reactions (favorite or good) from anyone, ever.
    var likes: [UUID: Int] = [:]
    var requests: [DatedRequest] = []
    /// Household items in stock (in or low), matched against meal ingredients.
    var onHandItemIDs: Set<UUID> = []
    /// Standing traditions, at most one per weekday.
    var traditions: [Tradition] = []
    /// The day the planner is building on. Nights before it already happened and are kept as they are,
    /// and advance prep (thawing) is counted from it.
    var today: CalendarDay

    /// `today` defaults to the first night, the usual Sunday-morning build. With no nights there's nothing
    /// to plan, so its value doesn't matter.
    init(
        nights: [PlanningNight], meals: [LibraryMeal], history: [MealHistory] = [],
        settings: HouseholdSettings = HouseholdSettings(), memberNames: [UUID: String] = [:],
        notForMe: [UUID: [UUID: Int]] = [:], snoozedMealIDs: Set<UUID> = [], favorites: [UUID: Set<UUID>] = [:],
        likes: [UUID: Int] = [:], requests: [DatedRequest] = [], onHandItemIDs: Set<UUID> = [],
        traditions: [Tradition] = [], today: CalendarDay? = nil
    ) {
        self.traditions = traditions
        (self.nights, self.meals, self.history, self.settings) = (nights, meals, history, settings)
        (self.memberNames, self.notForMe, self.snoozedMealIDs) = (memberNames, notForMe, snoozedMealIDs)
        (self.favorites, self.likes, self.requests, self.onHandItemIDs) = (favorites, likes, requests, onHandItemIDs)
        self.today = today ?? nights.map(\.date).min() ?? CalendarDay(year: 1970, month: 1, day: 1)
    }
}

/// What a night ends up holding.
enum NightPick: Equatable, Hashable, Sendable {
    case meal(UUID)
    case quickPick(QuickPick)

    var mealID: UUID? {
        if case .meal(let id) = self { id } else { nil }
    }

    var quickPick: QuickPick? {
        if case .quickPick(let pick) = self { pick } else { nil }
    }
}

/// One night of the draft.
struct NightPlan: Identifiable, Equatable, Sendable {
    let nightID: UUID
    let date: CalendarDay
    /// Nil when nothing fits: the card offers Pick for me or Choose.
    var pick: NightPick?
    /// The chip on the card. Nil only on nights already decided (pinned, events, or past).
    var reason: PlanReason?
    /// Pinned, event, a dated request, or already past: shuffle and rebuilds leave it alone.
    var isKept: Bool
    /// Saved locked: a tradition, so a rebuild keeps it and only a swap changes it for the week.
    var locks = false

    var id: UUID { nightID }
}

/// Why the draft picked what it did, shown as the day card's reason chip.
enum PlanReason: Equatable, Hashable, Sendable {
    case request(name: String?)
    case favorite(name: String?)
    case somethingNew
    case quickForRushedNight
    case usesWhatsOnHand
    /// Days since it was last made; one or more.
    case notHadIn(days: Int)
    case dueForATurn
    case familyLikesIt
    case bigBatch
    case leftoversAfterBigBatch
    case leftoversNight
    case takeoutOnBusiestNight
    case tradition(name: String?)
    /// Everyone's out: no dinner to plan, so nothing lands on the list.
    case nobodyHome
    case nothingFits

    var text: String {
        switch self {
        case .request(let name?):
            String(localized: "\(name)'s request", comment: "Day card badge: the member who asked for this dish")
        case .request(nil): String(localized: "Requested", comment: "Reason chip: someone asked for this dish")
        case .favorite(let name?): String(localized: "\(name)'s favorite", comment: "Reason chip: a member's favorite")
        case .favorite(nil): String(localized: "A family favorite", comment: "Reason chip")
        case .somethingNew: String(localized: "Something new", comment: "Reason chip: a dish the family hasn't tried")
        case .quickForRushedNight: String(localized: "Quick for a rushed night", comment: "Reason chip")
        case .usesWhatsOnHand: String(localized: "Uses what's on hand", comment: "Reason chip: ingredients in stock")
        case .notHadIn(let days) where days >= 14:
            String(localized: "Haven't had it in \(days / 7) weeks", comment: "Reason chip: weeks since last made")
        case .notHadIn(let days) where days >= 7:
            String(localized: "Haven't had it in a week", comment: "Reason chip: last made 7 to 13 days ago")
        case .notHadIn(let days) where days <= 1:
            String(localized: "Haven't had it since yesterday", comment: "Reason chip: last made yesterday")
        case .notHadIn(let days):
            String(localized: "Haven't had it in \(days) days", comment: "Reason chip: days since last made")
        case .dueForATurn: String(localized: "Due for a turn", comment: "Reason chip: a regular in the rotation")
        case .familyLikesIt: String(localized: "The family likes it", comment: "Reason chip")
        case .bigBatch: String(localized: "Makes leftovers for tomorrow", comment: "Reason chip: a big-batch meal")
        case .leftoversAfterBigBatch:
            String(localized: "Leftovers from last night", comment: "Reason chip: the night after a big batch")
        case .leftoversNight: String(localized: "Leftovers night", comment: "Reason chip")
        case .takeoutOnBusiestNight: String(localized: "Takeout on the busiest night", comment: "Reason chip")
        case .tradition(let name?): name
        case .tradition(nil): String(localized: "Tradition", comment: "Reason chip: a standing weekday tradition")
        case .nobodyHome: String(localized: "Nobody's home", comment: "Reason chip: everyone is out that night")
        case .nothingFits: String(localized: "Nothing fits tonight", comment: "Reason chip: no dish passed the filters")
        }
    }
}

extension CalendarDay {
    /// Whole days from `earlier` to this day, without a calendar or time zone, so daylight saving can't skew it.
    func days(since earlier: CalendarDay) -> Int {
        dayNumber - earlier.dayNumber
    }

    /// ISO weekday, 1 = Monday … 7 = Sunday, from the date alone.
    var isoWeekday: Int {
        // 1970-01-05 was a Monday.
        let offset = days(since: CalendarDay(year: 1970, month: 1, day: 5)) % 7
        return (offset + 7) % 7 + 1
    }

    /// Days since a fixed epoch on the proleptic Gregorian calendar (the civil-from-days algorithm, inverted).
    private var dayNumber: Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra
    }
}
