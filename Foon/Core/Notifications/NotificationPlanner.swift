import Foundation

/// What one person's device should have scheduled (docs/spec.md → Notifications), as a pure function of what it knows. No
/// randomness and no clock of its own: the same inputs give the same list, and running it again changes nothing.
///
/// Times are the household's: a wall-clock time on its calendar (`DinnerPrompts.calendar`, the same clock as the This Week card
/// and the server, so its time zone, daylight saving included) becomes one instant, whatever zone the phone is in. It fails toward not sending: data that's old, a week that isn't
/// approved, a night it can't read, or anything it isn't sure of means no reminder.
enum NotificationPlanner {
    struct Inputs: Sendable {
        var me: Member
        var members: [Member]
        var settings: HouseholdSettings
        /// Nil until this device has read the plan once.
        var snapshot: ReminderSnapshot?
        var history: [ReminderHistory] = []
        var now: Date
    }

    /// Nothing is planned from a read older than this: reminders about a week that could have changed since.
    static let maxDataAge: TimeInterval = 2 * 24 * 60 * 60
    /// Nor does anything go out further than this after that read, since the phone has no way to take it back if the app
    /// isn't opened. Long enough for a family that opens Foon on planning day to get the week.
    /// It can only touch two of the household's weeks, so budgets keep the plan to 32 at most: well inside iOS's 64 pending per
    /// app, with room for cook-mode timers. Raising a budget (#47) means checking that.
    static let horizon: TimeInterval = 8 * 24 * 60 * 60
    static let followUpDelay: TimeInterval = 60 * 60
    /// How far before a quiet stretch a prep reminder moves to, so it isn't the last thing at bedtime.
    static let quietMargin: TimeInterval = 15 * 60

    static func plan(_ inputs: Inputs) -> [PlannedReminder] {
        guard let snapshot = inputs.snapshot, inputs.settings.onboarded, inputs.me.status != .removed,
              inputs.now.timeIntervalSince(snapshot.pulledAt) <= maxDataAge else { return [] }
        let rules = ReminderRules(member: inputs.me, settings: inputs.settings)
        let context = Context(inputs: inputs, snapshot: snapshot, rules: rules)
        let due = context.candidates().compactMap(context.settled)
        return context.withinBudget(due).sorted(by: Self.byTime)
    }

    private static func byTime(_ lhs: PlannedReminder, _ rhs: PlannedReminder) -> Bool {
        (lhs.fireAt, lhs.id) < (rhs.fireAt, rhs.id)
    }

    /// A reminder before quiet hours, budgets, and what's been sent have had their say.
    private struct Candidate {
        let reminder: PlannedReminder
        var isFollowUp = false
    }

    private struct Context {
        let inputs: Inputs
        let snapshot: ReminderSnapshot
        let rules: ReminderRules
        let calendar: Calendar
        let today: CalendarDay
        let history: [String: ReminderHistory]

        init(inputs: Inputs, snapshot: ReminderSnapshot, rules: ReminderRules) {
            self.inputs = inputs
            self.snapshot = snapshot
            self.rules = rules
            calendar = DinnerPrompts.calendar(for: inputs.settings)
            today = CalendarDay(inputs.now, calendar: calendar)
            history = Dictionary(inputs.history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        private var me: Member { inputs.me }
        private var settings: HouseholdSettings { inputs.settings }

        func candidates() -> [Candidate] {
            let first = timeToPlan() + prep() + afterDinner() + checkIn()
            return rules.followsUp ? first + first.compactMap(followUp) : first
        }

        // MARK: - Rules

        /// The next planning times, for the week each one plans: the first to start on or after that day. Not for a week
        /// that's approved, or one the household is away for all of.
        private func timeToPlan() -> [Candidate] {
            guard rules.kinds.contains(.timeToPlan), me.role == .planner else { return [] }
            let days = (0..<14).map { today.adding(days: $0, calendar: calendar) }
                .filter { WeekMath.isoWeekday(of: $0, calendar: calendar) == settings.planningDay }
            return days.compactMap { day -> Candidate? in
                let thisWeek = WeekMath.start(of: day, weekStart: settings.weekStart, calendar: calendar)
                let week = thisWeek == day ? day : thisWeek.adding(days: 7, calendar: calendar)
                guard !me.isAway(today: day),
                      snapshot.weeks.first(where: { $0.start == week })?.isApproved != true,
                      !(0..<7).allSatisfy({ settings.isAway(on: week.adding(days: $0, calendar: calendar)) }),
                      let fire = DinnerPrompts.moment(settings.planningTime, on: day, calendar: calendar) else { return nil }
                return Candidate(reminder: PlannedReminder(
                    id: ReminderID.timeToPlan(me: me.id, week: week), kind: .timeToPlan, nightID: nil, fireAt: fire,
                    dinnerAt: nil, title: ReminderText.timeToPlanTitle, body: ReminderText.timeToPlanBody,
                    route: .week(week)))
            }
        }

        /// One per step that has a lead time, counted back from that night's dinner. A step without one has nothing to count
        /// from, and still shows on the card.
        private func prep() -> [Candidate] {
            guard rules.kinds.contains(.prep) else { return [] }
            return plannableNights().flatMap { night -> [Candidate] in
                guard let meal = night.mealID, night.quickPick == nil, !night.isAlreadyCooked,
                      remindsAboutPrep(night),
                      let dinner = DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date,
                                                        calendar: calendar) else { return [] }
                return night.prepSteps.enumerated().compactMap { index, step -> Candidate? in
                    guard let fire = counted(back: step.leadHours, from: dinner) else { return nil }
                    // The title waits until `settled` knows when it goes.
                    return Candidate(reminder: PlannedReminder(
                        id: ReminderID.prep(me: me.id, night: night.id, meal: meal, step: index), kind: .prep,
                        nightID: night.id, fireAt: fire, dinnerAt: dinner, title: "", body: ReminderText.prepBody(step.kind),
                        route: .night(night.id, night.date)))
                }
            }
        }

        /// Whoever was expected, about an hour after dinner, for a dish: the same rule and the same time as the card on This
        /// Week. Not for a quick pick, for someone who eats separately, or once they've rated it or someone's logged
        /// something else, since it's the wrong dish to ask about.
        private func afterDinner() -> [Candidate] {
            guard rules.kinds.contains(.afterDinner), DinnerPrompts.rates(me) else { return [] }
            return plannableNights().compactMap { night -> Candidate? in
                guard let meal = night.mealID, night.quickPick == nil,
                      night.attendance[me.id] == true, !me.isAway(today: night.date),
                      !night.ratedBy.contains(me.id), !night.hasLog || night.loggedMealID == meal,
                      let dinner = DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date,
                                                        calendar: calendar) else { return nil }
                return Candidate(reminder: PlannedReminder(
                    id: ReminderID.afterDinner(me: me.id, night: night.id, meal: meal), kind: .afterDinner,
                    nightID: night.id, fireAt: dinner.addingTimeInterval(DinnerPrompts.delay), dinnerAt: nil,
                    title: ReminderText.afterDinnerTitle, body: ReminderText.afterDinnerBody,
                    route: .dinnerCard))
            }
        }

        /// "Home tonight?", to whoever's expected, at the household's check-in time. Only with a dinner to come home to: not an
        /// empty night, not Fend for yourselves, and not once dinner's logged or they've answered on any phone.
        private func checkIn() -> [Candidate] {
            guard rules.kinds.contains(.checkIn) else { return [] }
            return plannableNights().compactMap { night -> Candidate? in
                guard DayOfCheckIn.hasDinnerToAskAbout(mealID: night.mealID, quickPick: night.quickPick), !night.hasLog,
                      night.attendance[me.id] == true, !night.checkedIn.contains(me.id), !me.isAway(today: night.date),
                      let dinner = DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date, calendar: calendar),
                      let fire = DinnerPrompts.moment(settings.checkInTime, on: night.date, calendar: calendar)
                else { return nil }
                return Candidate(reminder: PlannedReminder(
                    id: ReminderID.checkIn(me: me.id, night: night.id), kind: .checkIn, nightID: night.id, fireAt: fire,
                    dinnerAt: dinner, title: ReminderText.checkInTitle, body: ReminderText.checkInBody,
                    route: .checkIn(night: night.id, member: me.id)))
            }
        }

        /// One more an hour later, unless they've answered, and only after a first that went or is still to go: on its own
        /// it would be a reminder that came too late to send. Never after dinner, and never for a check-in, where no answer
        /// is an answer.
        private func followUp(_ first: Candidate) -> Candidate? {
            let reminder = first.reminder
            let known = history[reminder.id]
            guard reminder.kind != .afterDinner, reminder.kind != .checkIn, known?.respondedAt == nil,
                  let moved = settled(time: reminder.fireAt, for: reminder),
                  known?.sentAt != nil || moved > inputs.now else { return nil }
            return Candidate(reminder: PlannedReminder(
                id: ReminderID.followUp(of: reminder.id), kind: reminder.kind, nightID: reminder.nightID,
                fireAt: moved.addingTimeInterval(NotificationPlanner.followUpDelay), dinnerAt: reminder.dinnerAt,
                title: reminder.title, body: reminder.body, route: reminder.route), isFollowUp: true)
        }

        /// Nights of approved weeks that aren't in the away dates. A draft can still change, so it reminds nobody. Each rule
        /// then asks who's home, and a night gone by has no times left ahead.
        private func plannableNights() -> [ReminderNight] {
            snapshot.weeks.filter(\.isApproved).flatMap(\.nights).filter { !settings.isAway(on: $0.date) }
        }

        /// The docs' "planners, or whoever's home": the planners home that night, else the adults home. Only people with
        /// their own phone count, so a planner profile nobody's signed in to doesn't leave the night without anyone. Kids who
        /// don't plan aren't asked to thaw things.
        private func remindsAboutPrep(_ night: ReminderNight) -> Bool {
            let home = inputs.members.filter {
                $0.status != .removed && $0.userID != nil && night.attendance[$0.id] == true && !$0.isAway(today: night.date)
            }
            let planners = home.filter { $0.role == .planner }
            let chosen = planners.isEmpty ? home.filter { $0.ageGroup == .adult } : planners
            return chosen.contains { $0.id == me.id }
        }

        /// Whole days on the calendar, so a 24-hour thaw starts at the same clock time across a daylight saving change.
        private func counted(back hours: Int, from dinner: Date) -> Date? {
            calendar.date(byAdding: .day, value: -(hours / 24), to: dinner)?
                .addingTimeInterval(-TimeInterval(hours % 24) * 60 * 60)
        }

        // MARK: - What survives

        /// The reminder as it should go now, or nil: already sent or answered, too late, or too far off to trust.
        func settled(_ candidate: Candidate) -> Candidate? {
            let reminder = candidate.reminder
            let known = history[reminder.id]
            let fire: Date
            if let snoozed = known?.snoozedUntil, snoozed > inputs.now {
                // They asked for this time, so it goes then, quiet or not.
                fire = snoozed
            } else {
                guard known?.sentAt == nil, known?.respondedAt == nil,
                      let moved = settled(time: reminder.fireAt, for: reminder, isFollowUp: candidate.isFollowUp)
                else { return nil }
                fire = moved
            }
            guard fire > inputs.now, fire <= snapshot.pulledAt.addingTimeInterval(NotificationPlanner.horizon),
                  reminder.dinnerAt.map({ fire < $0 }) ?? true else { return nil }
            return Candidate(reminder: firing(reminder, at: fire), isFollowUp: candidate.isFollowUp)
        }

        /// The reminder as it goes at this time, with its words: a move can make tonight's dinner tomorrow's.
        private func firing(_ reminder: PlannedReminder, at date: Date) -> PlannedReminder {
            var title = reminder.title
            if case .night(_, let night) = reminder.route {
                title = ReminderText.prepTitle(night: night, firing: date, calendar: calendar)
            }
            return PlannedReminder(id: reminder.id, kind: reminder.kind, nightID: reminder.nightID, fireAt: date,
                                   dinnerAt: reminder.dinnerAt, title: title, body: reminder.body, route: reminder.route)
        }

        /// Out of quiet hours. A prep reminder goes just before them, or if that's gone by, when they end, as long as at least
        /// half its lead time is left before dinner. Time to plan goes later, since the week will still need planning, and so
        /// does a check-in, as long as that's before dinner. An after-dinner prompt, or a follow-up, just doesn't go: the card's
        /// still there.
        private func settled(time: Date, for reminder: PlannedReminder, isFollowUp: Bool = false) -> Date? {
            var moved = time
            for _ in 0..<4 {
                guard let quiet = rules.window(containing: moved, calendar: calendar) else { return moved }
                if isFollowUp { return nil }
                switch reminder.kind {
                case .prep:
                    let before = quiet.start.addingTimeInterval(-NotificationPlanner.quietMargin)
                    if before > inputs.now {
                        moved = before
                    } else {
                        guard let dinner = reminder.dinnerAt,
                              dinner.timeIntervalSince(quiet.end) >= dinner.timeIntervalSince(time) / 2 else { return nil }
                        moved = quiet.end
                    }
                case .timeToPlan, .checkIn: moved = quiet.end
                case .afterDinner: return nil
                }
            }
            return nil
        }

        /// Most important first, then soonest, until the week's budget runs out, counting what's already gone out that week.
        /// A snoozed reminder has already been counted.
        func withinBudget(_ due: [Candidate]) -> [PlannedReminder] {
            var used: [CalendarDay: Int] = [:]
            for sent in inputs.history.compactMap(\.sentAt) { used[week(of: sent), default: 0] += 1 }
            let ordered = due.sorted { lhs, rhs in
                let left = (lhs.isFollowUp ? 1 : 0, lhs.reminder.kind.budgetOrder), right = (rhs.isFollowUp ? 1 : 0, rhs.reminder.kind.budgetOrder)
                if left != right { return left < right }
                return NotificationPlanner.byTime(lhs.reminder, rhs.reminder)
            }
            return ordered.compactMap { candidate in
                let reminder = candidate.reminder
                if history[reminder.id]?.sentAt != nil { return reminder }
                let week = week(of: reminder.fireAt)
                guard used[week, default: 0] < rules.weeklyBudget else { return nil }
                used[week, default: 0] += 1
                return reminder
            }
        }

        private func week(of date: Date) -> CalendarDay {
            WeekMath.start(of: CalendarDay(date, calendar: calendar), weekStart: settings.weekStart, calendar: calendar)
        }
    }
}

/// Lock-screen words, kids' included, and every one of them is ours. No dish name, no words from a prep step, and no person's
/// name: a family types those, and no check of what they typed could be complete. The dish shows in the app after a tap.
enum ReminderText {
    static var timeToPlanTitle: String { String(localized: "Time to plan the week", comment: "Reminder title") }
    static var timeToPlanBody: String {
        String(localized: "Foon can draft it in a tap, and you can change any night.", comment: "Reminder body: time to plan")
    }
    static var afterDinnerTitle: String { String(localized: "How was dinner?", comment: "Reminder title") }
    static var afterDinnerBody: String {
        String(localized: "Tap to rate dinner.", comment: "Reminder body: rate the dish, never the cook")
    }

    /// Fixed words like the rest: the dish shows on the card, after a tap.
    static var checkInTitle: String { String(localized: "Home tonight?", comment: "Reminder title: the day-of check-in") }
    static var checkInBody: String {
        String(localized: "Tap to see what's for dinner.", comment: "Reminder body: the day-of check-in")
    }

    /// Which dinner, from when the reminder goes: quiet hours can move one to another day.
    static func prepTitle(night: CalendarDay, firing: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let fireDay = CalendarDay(firing, calendar: calendar)
        if fireDay == night { return String(localized: "Dinner tonight", comment: "Prep reminder title") }
        if fireDay.adding(days: 1, calendar: calendar) == night {
            return String(localized: "Dinner tomorrow", comment: "Prep reminder title")
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
        let weekday = night.date(in: calendar).formatted(style)
        return String(localized: "Dinner on \(weekday)", comment: "Prep reminder title: a weekday")
    }

    static func prepBody(_ kind: PrepKind) -> String {
        switch kind {
        case .thaw: String(localized: "Time to thaw what's for dinner.", comment: "Prep reminder body")
        case .marinate: String(localized: "Time to start the marinade.", comment: "Prep reminder body")
        case .slowCooker: String(localized: "Time to start the slow cooker.", comment: "Prep reminder body")
        case .other: String(localized: "Time to start prep.", comment: "Prep reminder body")
        }
    }
}
