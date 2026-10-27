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
    /// The chip on the card. Nil only on nights the planner already decided (pinned or events).
    var reason: PlanReason?
    /// Pinned, event, or a dated request: shuffle and rebuilds leave it alone.
    var isKept: Bool

    var id: UUID { nightID }
}

/// Why the draft picked what it did, shown as the day card's reason chip.
enum PlanReason: Equatable, Hashable, Sendable {
    case request(name: String?)
    case favorite(name: String?)
    case somethingNew
    case quickForRushedNight
    case usesWhatsOnHand
    case notHadIn(days: Int)
    case familyLikesIt
    case bigBatch
    case leftoversAfterBigBatch
    case leftoversNight
    case takeoutOnBusiestNight
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
        case .notHadIn(let days):
            String(localized: "Haven't had it in \(days) days", comment: "Reason chip: days since last made")
        case .familyLikesIt: String(localized: "The family likes it", comment: "Reason chip")
        case .bigBatch: String(localized: "Makes leftovers for tomorrow", comment: "Reason chip: a big-batch meal")
        case .leftoversAfterBigBatch:
            String(localized: "Leftovers from last night", comment: "Reason chip: the night after a big batch")
        case .leftoversNight: String(localized: "Leftovers night", comment: "Reason chip")
        case .takeoutOnBusiestNight: String(localized: "Takeout on the busiest night", comment: "Reason chip")
        case .nothingFits: String(localized: "Nothing fits tonight", comment: "Reason chip: no dish passed the filters")
        }
    }
}

extension CalendarDay {
    /// Whole days from `earlier` to this day, without a calendar or time zone, so daylight saving can't skew it.
    func days(since earlier: CalendarDay) -> Int {
        dayNumber - earlier.dayNumber
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
