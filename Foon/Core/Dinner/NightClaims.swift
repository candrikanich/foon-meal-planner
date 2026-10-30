import Foundation

/// "I'll cook Thursday" (`night_claims`): a promise, read as it stands, with what its night looks like now. Only open
/// claims are loaded.
struct NightClaim: Identifiable, Equatable, Sendable, Decodable {
    let id: UUID
    let nightID: UUID
    let memberID: UUID
    /// Whose phone it was: themselves, or someone passing the phone.
    let enteredByMemberID: UUID?
    let date: CalendarDay
    /// The night's plan and whether they're out, for what's beyond the week on screen (the planner's note).
    let nightMealID: UUID?
    let nightQuickPick: QuickPick?
    let memberIsOut: Bool

    init(id: UUID = UUID(), nightID: UUID, memberID: UUID, enteredByMemberID: UUID? = nil, date: CalendarDay,
         nightMealID: UUID? = nil, nightQuickPick: QuickPick? = nil, memberIsOut: Bool = false) {
        self.id = id
        self.nightID = nightID
        self.memberID = memberID
        self.enteredByMemberID = enteredByMemberID
        self.date = date
        self.nightMealID = nightMealID
        self.nightQuickPick = nightQuickPick
        self.memberIsOut = memberIsOut
    }

    /// The columns to select for it.
    static let columns = """
        id, night_id, member_id, entered_by_member_id, \
        plan_nights!inner(date, meal_id, quick_pick, night_attendance(member_id, expected))
        """

    private enum CodingKeys: String, CodingKey {
        case id
        case nightID = "night_id"
        case memberID = "member_id"
        case enteredByMemberID = "entered_by_member_id"
        case night = "plan_nights"
    }

    private struct Night: Decodable {
        let date: CalendarDay
        let mealID: UUID?
        let quickPick: QuickPick?
        let attendance: [Attendance]

        private enum CodingKeys: String, CodingKey {
            case date
            case mealID = "meal_id"
            case quickPick = "quick_pick"
            case attendance = "night_attendance"
        }
    }

    private struct Attendance: Decodable {
        let memberID: UUID
        let expected: Bool

        private enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
            case expected
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nightID = try container.decode(UUID.self, forKey: .nightID)
        let member = try container.decode(UUID.self, forKey: .memberID)
        memberID = member
        enteredByMemberID = try container.decodeIfPresent(UUID.self, forKey: .enteredByMemberID)
        let night = try container.decode(Night.self, forKey: .night)
        date = night.date
        nightMealID = night.mealID
        nightQuickPick = night.quickPick
        memberIsOut = night.attendance.first { $0.memberID == member }?.expected == false
    }
}

/// What a claim means right now (docs/spec.md → Claim a night). Nothing keeps a claim in step with its night: these rules
/// read both, and the server's `claim_night` and `night_claimer` go by the same ones. Pure, so each way a night can change
/// is tested.
enum NightClaims {
    enum Standing: Equatable, Sendable {
        /// They're down as the night's cook.
        case cooking
        /// The promise is still there but can't be kept as things are. It counts again if the night changes back.
        case onHold(Hold)
    }

    enum Hold: Equatable, Sendable {
        case quickPick(QuickPick)
        case out
    }

    /// Nil when it doesn't count at all: the night reads as away, or they're gone, or they eat separately now.
    static func standing(of claim: NightClaim, on night: WeekNight, members: [Member], away: [AwayDates],
                         today: CalendarDay) -> Standing? {
        standing(memberID: claim.memberID, quickPick: night.quickPick, isOut: night.attendance[claim.memberID] == false,
                 readsAway: night.readsAway(in: away, today: today), members: members)
    }

    private static func standing(memberID: UUID, quickPick: QuickPick?, isOut: Bool, readsAway: Bool,
                                 members: [Member]) -> Standing? {
        guard !readsAway, let member = members.first(where: { $0.id == memberID }), member.status != .removed,
              !member.eatsSeparately else { return nil }
        if let quickPick { return .onHold(.quickPick(quickPick)) }
        return isOut ? .onHold(.out) : .cooking
    }

    static func claim(on nightID: UUID, in claims: [NightClaim]) -> NightClaim? {
        claims.first { $0.nightID == nightID }
    }

    /// Whether this person can say they'll cook: a night still ahead, nothing logged, something to cook, not out, and
    /// nobody else down as cooking. A claim on hold because its person is out doesn't stop anyone.
    static func canClaim(_ member: Member, night: WeekNight, claims: [NightClaim], log: DinnerLog?, members: [Member],
                         away: [AwayDates], today: CalendarDay) -> Bool {
        guard night.date >= today, log == nil, night.quickPick == nil, !night.readsAway(in: away, today: today),
              member.status != .removed, !member.eatsSeparately, night.attendance[member.id] != false else { return false }
        guard let held = claim(on: night.id, in: claims) else { return true }
        return standing(of: held, on: night, members: members, away: away, today: today) != .cooking
    }

    /// Who can offer on this phone: you first, then anyone with no account of their own (pass the phone).
    static func whoCanClaim(me: Member, night: WeekNight, claims: [NightClaim], log: DinnerLog?, members: [Member],
                            away: [AwayDates], today: CalendarDay) -> [Member] {
        let others = DinnerPrompts.raters(home: members, me: me.id).filter { $0.id != me.id }
        return ([me] + others).filter {
            canClaim($0, night: night, claims: claims, log: log, members: members, away: away, today: today)
        }
    }

    /// Same rule as the server: themselves, a profile nobody has claimed, or a planner.
    static func canRelease(_ claim: NightClaim, me: Member?, canPlan: Bool, members: [Member]) -> Bool {
        guard let me else { return canPlan }
        if canPlan || claim.memberID == me.id { return true }
        return members.first { $0.id == claim.memberID }?.userID == nil
    }

    /// What the card says about who's cooking. Once there's a log, it goes by the log: a promise doesn't outlive what
    /// happened. A night gone by with no log says nothing.
    static func cookLine(night: WeekNight, claims: [NightClaim], log: DinnerLog?, members: [Member], me: UUID?,
                         away: [AwayDates], today: CalendarDay) -> DayCardModel.Cook? {
        if let log {
            guard log.mealID != nil, let cook = log.cookedByMemberID, let member = members.first(where: { $0.id == cook })
            else { return nil }
            return DayCardModel.Cook(member: member, isYou: member.id == me, tense: .cooked)
        }
        guard night.date >= today, let held = claim(on: night.id, in: claims),
              standing(of: held, on: night, members: members, away: away, today: today) == .cooking,
              let member = members.first(where: { $0.id == held.memberID }) else { return nil }
        return DayCardModel.Cook(member: member, isYou: member.id == me, tense: .willCook)
    }

    /// Who dinner jobs give the night off: whoever's claim stands. Claims only, not logs, past nights included: answering
    /// who cooked last night mustn't change who has the dishes tomorrow, and nor must a promised night going by.
    static func cooks(nights: [WeekNight], claims: [NightClaim], members: [Member], away: [AwayDates],
                      today: CalendarDay) -> [UUID: UUID] {
        var cooks: [UUID: UUID] = [:]
        for night in nights {
            guard let held = claim(on: night.id, in: claims),
                  standing(of: held, on: night, members: members, away: away, today: today) == .cooking else { continue }
            cooks[night.id] = held.memberID
        }
        return cooks
    }

    /// The planner's note (docs/spec.md → Claim a night): someone else offering, on a night still ahead, that counts as
    /// it stands. Not what you entered yourself, and not what's dismissed on this device. Goes by `nights` (the week on
    /// screen, as fresh as the card) where it can, and what the claim was read with for a night beyond them.
    static func news(claims: [NightClaim], nights: [WeekNight] = [], me: UUID?, canPlan: Bool, members: [Member],
                     logged: Set<UUID>, away: [AwayDates], today: CalendarDay, dismissed: Set<UUID>) -> [NightClaim] {
        guard canPlan else { return [] }
        return claims.filter { claim in
            guard claim.date >= today, !dismissed.contains(claim.id), !logged.contains(claim.nightID), claim.memberID != me,
                  claim.enteredByMemberID != me else { return false }
            if let night = nights.first(where: { $0.id == claim.nightID }) {
                return standing(of: claim, on: night, members: members, away: away, today: today) == .cooking
            }
            let planned = claim.nightMealID != nil || claim.nightQuickPick != nil
            let readsAway = away.contains { $0.contains(claim.date) } && !(claim.date <= today && planned)
            return standing(memberID: claim.memberID, quickPick: claim.nightQuickPick, isOut: claim.memberIsOut,
                            readsAway: readsAway, members: members) == .cooking
        }
        .sorted { $0.date < $1.date }
    }
}

/// The words about claims, kept out of the views so they're testable and localizable.
enum ClaimText {
    private enum When {
        case tonight, tomorrow
        case later(String)
    }

    /// A night more than a week off also says its date: "Thursday" would read as this Thursday.
    private static func when(_ day: CalendarDay, today: CalendarDay, calendar: Calendar) -> When {
        if day == today { return .tonight }
        if day == today.adding(days: 1, calendar: calendar) { return .tomorrow }
        let weekday = DayCardText.dayLabel(for: day, today: today, calendar: calendar)
        guard day > today.adding(days: 6, calendar: calendar) else { return .later(weekday) }
        return .later("\(weekday), \(DayCardText.dateLabel(for: day, calendar: calendar))")
    }

    /// "I'll cook Thursday".
    static func offer(_ day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        switch when(day, today: today, calendar: calendar) {
        case .tonight: String(localized: "I'll cook tonight")
        case .tomorrow: String(localized: "I'll cook tomorrow")
        case .later(let day): String(localized: "I'll cook \(day)", comment: "Offer to cook: a weekday, maybe with its date")
        }
    }

    /// "Nora will cook Thursday": pass the phone, and the planner's note.
    static func willCook(_ name: String, _ day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        switch when(day, today: today, calendar: calendar) {
        case .tonight: String(localized: "\(name) will cook tonight")
        case .tomorrow: String(localized: "\(name) will cook tomorrow")
        case .later(let day):
            String(localized: "\(name) will cook \(day)", comment: "Someone offering to cook: their name, then a weekday, maybe with its date")
        }
    }

    /// A button, passing the phone: "Put Nora down to cook Thursday".
    static func putDown(_ name: String, _ day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        switch when(day, today: today, calendar: calendar) {
        case .tonight: String(localized: "Put \(name) down to cook tonight")
        case .tomorrow: String(localized: "Put \(name) down to cook tomorrow")
        case .later(let day):
            String(localized: "Put \(name) down to cook \(day)", comment: "Button, passing the phone: their name, then a weekday, maybe with its date")
        }
    }

    /// Why a claim on hold isn't showing on the card.
    static func onHold(_ name: String, _ hold: NightClaims.Hold) -> String {
        switch hold {
        case .quickPick(let pick):
            let night = DayCardText.quickPickLabel(pick)
            return String(localized: "\(name) offered to cook, but this night is \(night) now.",
                          comment: "A claim on hold: their name, then the quick pick now on the night")
        case .out:
            return String(localized: "\(name) offered to cook, but is out this night now. Someone else can take it.")
        }
    }
}
