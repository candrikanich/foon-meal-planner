import Foundation
import Testing
@testable import Foon

/// Sunday Nov 8, 2026 starts the week, in New York. It's Sunday at 10am unless a test says otherwise, so this morning's
/// planning time has gone by.
private enum Fixture {
    static let zone = "America/New_York"
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func day(_ day: Int) -> CalendarDay { CalendarDay(year: 2026, month: 11, day: day) }

    static let ann = Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: UUID())
    static let ben = Member.fixture(firstName: "Ben", guardian: true, userID: UUID())
    static let kim = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: UUID())
    static let family = [ann, ben, kim]
    static let chili = UUID()
    static let thaw = PrepStep(step: "Move the beef to the fridge", leadHours: 24)

    static var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = zone
        return settings
    }

    static func night(_ day: Int, meal: UUID? = chili, steps: [PrepStep] = [],
                      home: [Member] = family, out: [Member] = []) -> ReminderNight {
        var attendance = Dictionary(uniqueKeysWithValues: home.map { ($0.id, true) })
        for member in out { attendance[member.id] = false }
        return ReminderNight(id: UUID(), date: Self.day(day), mealID: meal, prepSteps: steps.compactMap(ReminderPrep.init), attendance: attendance)
    }

    static func week(_ nights: [ReminderNight], start: Int = 8, approved: Bool = true) -> ReminderWeek {
        ReminderWeek(planID: UUID(), start: Self.day(start), isApproved: approved, nights: nights)
    }

    static func inputs(me: Member = ann, members: [Member] = family, settings: HouseholdSettings = settings,
                       weeks: [ReminderWeek] = [], history: [ReminderHistory] = [],
                       now: Date = at(8, 10), pulledAt: Date? = nil) -> NotificationPlanner.Inputs {
        NotificationPlanner.Inputs(me: me, members: members, settings: settings,
                                   snapshot: ReminderSnapshot(pulledAt: pulledAt ?? now, weeks: weeks),
                                   history: history, now: now)
    }

    static func plan(me: Member = ann, members: [Member] = family, settings: HouseholdSettings = settings,
                     weeks: [ReminderWeek] = [], history: [ReminderHistory] = [], now: Date = at(8, 10),
                     pulledAt: Date? = nil) -> [PlannedReminder] {
        NotificationPlanner.plan(inputs(me: me, members: members, settings: settings, weeks: weeks, history: history,
                                        now: now, pulledAt: pulledAt))
    }

    static func of(_ kind: ReminderKind, _ reminders: [PlannedReminder]) -> [PlannedReminder] {
        reminders.filter { $0.kind == kind }
    }
}

private typealias F = Fixture

@Suite struct TimeToPlanReminderTests {
    @Test func aPlannerIsRemindedOnPlanningDayAtPlanningTime() throws {
        let reminder = try #require(F.of(.timeToPlan, F.plan(now: F.at(8, 8))).first)
        #expect(reminder.fireAt == F.at(8, 9))
        #expect(reminder.route == .week(F.day(8)))
        #expect(reminder.nightID == nil)
    }

    @Test func nobodyElseIs() {
        #expect(F.of(.timeToPlan, F.plan(me: F.ben, now: F.at(8, 8))).isEmpty)
        #expect(F.of(.timeToPlan, F.plan(me: F.kim, now: F.at(8, 8))).isEmpty)
    }

    @Test func onceTodaysTimeHasGoneItIsNextWeeksTurn() throws {
        let reminder = try #require(F.of(.timeToPlan, F.plan()).first)
        #expect(reminder.fireAt == F.at(15, 9))
        #expect(reminder.route == .week(F.day(15)))
    }

    @Test func anApprovedWeekNeedsNoReminder() {
        let approved = F.week([], approved: true)
        #expect(!F.plan(weeks: [approved], now: F.at(8, 8)).contains { $0.route == .week(F.day(8)) })
    }

    @Test func aWeekStartedButNotApprovedStillDoes() {
        let draft = F.week([F.night(9)], approved: false)
        #expect(F.plan(weeks: [draft], now: F.at(8, 8)).contains { $0.route == .week(F.day(8)) })
    }

    @Test func aWeekAllAwayIsSkippedAndOnePartlyAwayIsNot() {
        var settings = F.settings
        settings.awayDates = [AwayDates(from: F.day(8), to: F.day(14))]
        #expect(!F.plan(settings: settings, now: F.at(8, 8)).contains { $0.route == .week(F.day(8)) })
        settings.awayDates = [AwayDates(from: F.day(8), to: F.day(13))]
        #expect(F.plan(settings: settings, now: F.at(8, 8)).contains { $0.route == .week(F.day(8)) })
    }

    @Test func planningOnAnotherDayPlansTheWeekThatStartsNext() throws {
        var settings = F.settings
        settings.planningDay = 3 // Wednesday, for a week starting Sunday
        let reminder = try #require(F.of(.timeToPlan, F.plan(settings: settings)).first)
        #expect(reminder.fireAt == F.at(11, 9))
        #expect(reminder.route == .week(F.day(15)))
    }

    @Test func aPlannerWhoIsAwayIsLeftAlone() {
        let away = Member.fixture(id: F.ann.id, firstName: "Ann", role: .planner, status: .away, userID: F.ann.userID)
        #expect(F.of(.timeToPlan, F.plan(me: away, members: [away, F.ben], now: F.at(8, 8))).isEmpty)
    }
}

@Suite struct PrepReminderTests {
    @Test func aStepFiresItsLeadTimeBeforeThatNightsDinner() throws {
        var night = F.night(10, steps: [F.thaw])
        night.dinnerTime = "19:30:00"
        let reminder = try #require(F.of(.prep, F.plan(weeks: [F.week([night])])).first)
        #expect(reminder.fireAt == F.at(9, 19, 30))
        #expect(reminder.dinnerAt == F.at(10, 19, 30))
        #expect(reminder.route == .night(night.id, F.day(10)))
        #expect(reminder.title == "Dinner tomorrow")
        #expect(reminder.body == "Time to start prep.", "the step's own words stay off the lock screen")
    }

    @Test func everyStepWithALeadTimeGetsOne() {
        let steps = [F.thaw, PrepStep(step: "Start the slow cooker", leadHours: 8), PrepStep(step: "Soak", leadHours: nil)]
        let fires = F.of(.prep, F.plan(weeks: [F.week([F.night(10, steps: steps)])])).map(\.fireAt)
        #expect(fires == [F.at(9, 18), F.at(10, 10)], "a step with no lead time has nothing to count from")
    }

    @Test func anUnapprovedWeekRemindsNobody() {
        let draft = F.week([F.night(10, steps: [F.thaw])], approved: false)
        #expect(F.of(.prep, F.plan(weeks: [draft])).isEmpty)
    }

    @Test func aFreezerNightHasNoPrep() {
        var night = F.night(10, steps: [F.thaw])
        night.stashItemID = UUID()
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])])).isEmpty)
    }

    @Test func aLeftoversNightHasNoPrep() {
        var night = F.night(10, steps: [F.thaw])
        night.leftoversFrom = UUID()
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])])).isEmpty)
    }

    @Test func aQuickPickHasNoPrep() {
        var takeout = F.night(10, meal: nil, steps: [F.thaw])
        takeout.quickPick = .takeout
        var both = F.night(11, steps: [F.thaw])
        both.quickPick = .takeout
        #expect(F.of(.prep, F.plan(weeks: [F.week([takeout, both])])).isEmpty)
    }

    @Test func aNightWithNobodyHomeHasNone() {
        let empty = F.night(10, steps: [F.thaw], home: [], out: F.family)
        #expect(F.of(.prep, F.plan(weeks: [F.week([empty])])).isEmpty)
    }

    @Test func aNightWithNoAttendanceRowsHasNone() {
        let unknown = F.night(10, steps: [F.thaw], home: [])
        #expect(F.of(.prep, F.plan(weeks: [F.week([unknown])])).isEmpty)
    }

    @Test func nothingIsSentAboutAnAwayNight() {
        var settings = F.settings
        settings.awayDates = [AwayDates(from: F.day(10), to: F.day(10))]
        let weeks = [F.week([F.night(10, steps: [F.thaw]), F.night(11, steps: [F.thaw])])]
        #expect(F.of(.prep, F.plan(settings: settings, weeks: weeks)).map(\.fireAt) == [F.at(10, 18)])
    }

    @Test func aPastNightHasNone() {
        let weeks = [F.week([F.night(8, steps: [PrepStep(step: "Thaw", leadHours: 2)])])]
        #expect(F.of(.prep, F.plan(weeks: weeks, now: F.at(9, 8))).isEmpty)
    }

    @Test func oneThatsAlreadyTooLateIsntSent() {
        let weeks = [F.week([F.night(8, steps: [F.thaw, PrepStep(step: "Marinate", leadHours: 4)])])]
        #expect(F.of(.prep, F.plan(weeks: weeks, now: F.at(8, 14, 1))).isEmpty, "both times have gone by")
        #expect(F.of(.prep, F.plan(weeks: weeks, now: F.at(8, 13, 59))).map(\.fireAt) == [F.at(8, 14)])
    }

    @Test func thePlannersHomeThatNightGetIt() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        #expect(!F.of(.prep, F.plan(me: F.ann, weeks: weeks)).isEmpty)
        #expect(F.of(.prep, F.plan(me: F.ben, weeks: weeks)).isEmpty, "an adult who doesn't plan isn't asked too")
        #expect(F.of(.prep, F.plan(me: F.kim, weeks: weeks)).isEmpty)
    }

    @Test func withNoPlannerHomeTheAdultsHomeGetIt() {
        let night = F.night(10, steps: [F.thaw], home: [F.ben, F.kim], out: [F.ann])
        let weeks = [F.week([night])]
        #expect(F.of(.prep, F.plan(me: F.ann, weeks: weeks)).isEmpty, "she's out")
        #expect(!F.of(.prep, F.plan(me: F.ben, weeks: weeks)).isEmpty)
        #expect(F.of(.prep, F.plan(me: F.kim, weeks: weeks)).isEmpty, "a kid isn't asked to thaw things")
    }

    @Test func aPlannerProfileNobodySignedInToDoesntLeaveTheNightWithoutAnyone() {
        let unclaimed = Member.fixture(firstName: "Gran", role: .planner)
        let night = F.night(10, steps: [F.thaw], home: [unclaimed, F.ben], out: [F.ann])
        #expect(!F.of(.prep, F.plan(me: F.ben, members: F.family + [unclaimed], weeks: [F.week([night])])).isEmpty)
    }

    @Test func someoneAwayByDateIsntHomeWhateverAttendanceSays() {
        let away = Member.fixture(id: F.ann.id, firstName: "Ann", role: .planner, status: .away,
                                  awayUntil: F.day(12), userID: F.ann.userID)
        let weeks = [F.week([F.night(10, steps: [F.thaw]), F.night(13, steps: [F.thaw])])]
        #expect(F.of(.prep, F.plan(me: away, members: [away, F.ben, F.kim], weeks: weeks)).map(\.fireAt) == [F.at(12, 18)],
                "not the 10th, and the 13th once she's back")
        #expect(F.of(.prep, F.plan(me: F.ben, members: [away, F.ben, F.kim], weeks: weeks)).map(\.fireAt) == [F.at(9, 18)])
    }

    @Test func aKidWhoPlansGetsItWithinHerOwnRules() {
        let teen = Member.fixture(firstName: "Tess", ageGroup: .kid, role: .planner, userID: UUID())
        let weeks = [F.week([F.night(10, steps: [F.thaw], home: [teen, F.ben])])]
        #expect(!F.of(.prep, F.plan(me: teen, members: [teen, F.ben], weeks: weeks)).isEmpty)
    }

    @Test func aChangedDishIsADifferentReminderAndTheOldOneNoLongerCounts() throws {
        let night = F.night(10, steps: [F.thaw])
        let before = try #require(F.of(.prep, F.plan(weeks: [F.week([night])])).first)
        var swapped = night
        swapped.mealID = UUID()
        let history = [ReminderHistory(id: before.id, sentAt: F.at(8, 9))]
        let after = try #require(F.of(.prep, F.plan(weeks: [F.week([swapped])], history: history)).first)
        #expect(after.id != before.id)
        #expect(after.title == "Dinner tomorrow")
    }

    @Test func aMovedDinnerMovesTheSameReminder() throws {
        var night = F.night(10, steps: [F.thaw])
        let before = try #require(F.of(.prep, F.plan(weeks: [F.week([night])])).first)
        night.dinnerTime = "20:00"
        let after = try #require(F.of(.prep, F.plan(weeks: [F.week([night])])).first)
        #expect(after.id == before.id)
        #expect(after.fireAt == F.at(9, 20))
    }

    @Test func oneAlreadySentIsntSentAgainEvenIfDinnerMoves() {
        var night = F.night(10, steps: [F.thaw])
        let id = F.of(.prep, F.plan(weeks: [F.week([night])]))[0].id
        night.dinnerTime = "21:00"
        let history = [ReminderHistory(id: id, sentAt: F.at(9, 18))]
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])], history: history, now: F.at(9, 18, 30))).isEmpty)
    }

    @Test func aPrepStepOfTheTitleReadsTheDay() {
        let weeks = [F.week([F.night(8, steps: [PrepStep(step: "Marinate", leadHours: 4)]),
                             F.night(13, steps: [PrepStep(step: "Soak", leadHours: 72)])])]
        let titles = F.of(.prep, F.plan(weeks: weeks)).map(\.title)
        #expect(titles.first == "Dinner tonight")
        #expect(titles.last == "Dinner on Friday")
    }
}

@Suite struct AfterDinnerReminderTests {
    @Test func whoeverWasExpectedIsAskedAnHourAfterDinnerAboutTheDish() throws {
        let night = F.night(10)
        let reminder = try #require(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).first)
        #expect(reminder.fireAt == F.at(10, 19))
        #expect(reminder.route == .dinnerCard)
        #expect(reminder.body == "Tap to rate dinner.")
    }

    @Test func itsTheSameMomentTheCardOnThisWeekOpens() throws {
        let night = F.night(10)
        let reminder = try #require(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).first)
        let card = WeekNight(id: night.id, date: night.date, effort: .normal, dinnerTime: nil, mealID: night.mealID,
                             mealName: nil, quickPick: nil, locked: false, attendance: night.attendance)
        #expect(DinnerPrompts.promptTime(card, defaultDinnerTime: F.settings.dinnerTime, calendar: F.calendar) == reminder.fireAt)
    }

    @Test func aNightOffOverridesTheHouseholdDinnerTime() throws {
        var night = F.night(10)
        night.dinnerTime = "17:15:00"
        #expect(F.of(.afterDinner, F.plan(weeks: [F.week([night])])).first?.fireAt == F.at(10, 18, 15))
    }

    @Test func someoneWhoEatsSeparatelyIsntAsked() {
        var tot = Member.fixture(firstName: "Tot", ageGroup: .kid, userID: UUID())
        tot.eatsSeparately = true
        let weeks = [F.week([F.night(10, home: F.family + [tot])])]
        #expect(F.of(.afterDinner, F.plan(me: tot, members: F.family + [tot], weeks: weeks)).isEmpty)
    }

    @Test func someoneOutThatNightIsntAsked() {
        let weeks = [F.week([F.night(10, home: [F.ann], out: [F.kim])])]
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: weeks)).isEmpty)
    }

    @Test func someoneAddedAfterTheWeekWasMadeIsntAsked() {
        let weeks = [F.week([F.night(10, home: [F.ann])])]
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: weeks)).isEmpty, "no attendance row, the same as the card")
    }

    @Test func aQuickPickIsntRated() {
        var night = F.night(10, meal: nil)
        night.quickPick = .takeout
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
    }

    @Test func aFreezerNightIsStillADishToRate() {
        var night = F.night(10)
        night.stashItemID = UUID()
        #expect(!F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
    }

    @Test func someoneWhoAlreadyRatedItIsntAsked() {
        var night = F.night(10)
        night.ratedBy = [F.kim.id]
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
        #expect(!F.of(.afterDinner, F.plan(me: F.ben, weeks: [F.week([night])])).isEmpty, "someone else's rating is theirs")
    }

    @Test func whenSomeoneLoggedSomethingElseTheOldDishIsntNamed() {
        var night = F.night(10)
        night.hasLog = true
        night.loggedMealID = UUID()
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
        night.loggedMealID = night.mealID
        #expect(!F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
    }

    @Test func aLoggedQuickPickIsSomethingElseToo() {
        var night = F.night(10)
        night.hasLog = true
        night.loggedMealID = nil
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty,
                "logged as takeout: a log with no dish isn't the same as no log")
        night.loggedMealID = night.mealID
        #expect(!F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty)
    }

    @Test func anUnapprovedWeekAndAnAwayNightAskNobody() {
        var settings = F.settings
        settings.awayDates = [AwayDates(from: F.day(10), to: F.day(10))]
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([F.night(10)], approved: false)])).isEmpty)
        #expect(F.of(.afterDinner, F.plan(me: F.kim, settings: settings, weeks: [F.week([F.night(10)])])).isEmpty)
    }

    @Test func tonightsStillComesWhileTheTimeIsAhead() {
        let weeks = [F.week([F.night(8)])]
        #expect(!F.of(.afterDinner, F.plan(weeks: weeks, now: F.at(8, 18, 30))).isEmpty)
        #expect(F.of(.afterDinner, F.plan(weeks: weeks, now: F.at(8, 19, 1))).isEmpty)
    }
}

@Suite struct ReminderPresetTests {
    private func settings(_ preset: HouseholdSettings.NotificationPreset) -> HouseholdSettings {
        var settings = F.settings
        settings.notificationPreset = preset
        return settings
    }

    @Test func lightHasNoRatingPrompts() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        let light = F.plan(settings: settings(.light), weeks: weeks)
        #expect(F.of(.afterDinner, light).isEmpty)
        #expect(!F.of(.prep, light).isEmpty)
        #expect(!F.of(.timeToPlan, light).isEmpty)
    }

    @Test func kidsGetAlmostNothingOnLight() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        #expect(F.plan(me: F.kim, settings: settings(.light), weeks: weeks).isEmpty)
    }

    @Test func balancedAddsThem() {
        let weeks = [F.week([F.night(10)])]
        #expect(!F.of(.afterDinner, F.plan(settings: settings(.balanced), weeks: weeks)).isEmpty)
    }

    @Test func onlyEngagedFollowsUp() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        let balanced = F.of(.prep, F.plan(settings: settings(.balanced), weeks: weeks))
        #expect(balanced.count == 1)
        let engaged = F.of(.prep, F.plan(settings: settings(.engaged), weeks: weeks))
        #expect(engaged.map(\.fireAt) == [F.at(9, 18), F.at(9, 19)])
        #expect(engaged[1].id == ReminderID.followUp(of: engaged[0].id))
    }

    @Test func aFollowUpGoesOnceTheFirstHasAndNotOnceItsAnswered() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        let id = F.of(.prep, F.plan(settings: settings(.engaged), weeks: weeks))[0].id
        let sent = ReminderHistory(id: id, sentAt: F.at(9, 18))
        let waiting = F.of(.prep, F.plan(settings: settings(.engaged), weeks: weeks, history: [sent], now: F.at(9, 18, 30)))
        #expect(waiting.map(\.id) == [ReminderID.followUp(of: id)])
        let answered = ReminderHistory(id: id, sentAt: F.at(9, 18), respondedAt: F.at(9, 18, 20))
        #expect(F.of(.prep, F.plan(settings: settings(.engaged), weeks: weeks, history: [answered],
                                   now: F.at(9, 18, 30))).isEmpty)
    }

    @Test func aFollowUpNeverComesAfterDinnerOrOnItsOwn() {
        let close = [F.week([F.night(10, steps: [PrepStep(step: "Soak", leadHours: 1)])])]
        #expect(F.of(.prep, F.plan(settings: settings(.engaged), weeks: close)).count == 1, "the follow-up would be at dinner")
        let late = [F.week([F.night(10, steps: [PrepStep(step: "Soak", leadHours: 2)])])]
        #expect(F.of(.prep, F.plan(settings: settings(.engaged), weeks: late, now: F.at(10, 16, 30))).isEmpty,
                "the first came too late to send, so the second doesn't go alone")
    }

    @Test func aFollowUpInQuietHoursDoesntGo() {
        let weeks = [F.week([F.night(10, steps: [PrepStep(step: "Soak", leadHours: 22)])])]
        // 8pm, and its follow-up would be 9pm.
        #expect(F.of(.prep, F.plan(settings: settings(.engaged), weeks: weeks)).map(\.fireAt) == [F.at(9, 20)])
    }

    @Test func afterDinnerPromptsDontFollowUp() {
        let weeks = [F.week([F.night(10)])]
        #expect(F.of(.afterDinner, F.plan(settings: settings(.engaged), weeks: weeks)).count == 1)
    }

    @Test func aPersonsOwnPresetWins() {
        var ben = F.ben
        ben.notificationPrefs = NotificationPrefs(preset: .light)
        #expect(F.of(.afterDinner, F.plan(me: ben, members: [F.ann, ben, F.kim], weeks: [F.week([F.night(10)])])).isEmpty)
    }

    @Test func kidsCanOnlyTurnTheirsDown() {
        var kim = F.kim
        kim.notificationPrefs = NotificationPrefs(preset: .light)
        #expect(ReminderRules.preset(member: kim, household: .balanced) == .light)
        kim.notificationPrefs = NotificationPrefs(preset: .engaged)
        #expect(ReminderRules.preset(member: kim, household: .balanced) == .balanced)
        var ben = F.ben
        ben.notificationPrefs = NotificationPrefs(preset: .engaged)
        #expect(ReminderRules.preset(member: ben, household: .balanced) == .engaged, "adults can go either way")
    }

    @Test func prefsThisVersionCantReadMeanNoOverride() throws {
        let decode: (String) throws -> NotificationPrefs = {
            try JSONDecoder().decode(NotificationPrefs.self, from: Data($0.utf8))
        }
        #expect(try decode(#"{"preset": "light"}"#).preset == .light)
        #expect(try decode(#"{"preset": "loud"}"#).preset == nil)
        #expect(try decode(#"{"preset": 3}"#).preset == nil)
        #expect(try decode("{}").preset == nil)
        #expect(try decode("[]").preset == nil)
    }
}

@Suite struct ReminderBudgetTests {
    private let everyNight = F.week((8...14).map { F.night($0) })

    @Test func aKidGetsFiveOnBalancedSoonestFirst() {
        let plan = F.plan(me: F.kim, weeks: [everyNight], now: F.at(8, 9))
        #expect(plan.map(\.fireAt) == [8, 9, 10, 11, 12].map { F.at($0, 19) })
    }

    @Test func whatsAlreadyGoneOutThisWeekCounts() {
        let sent = (0..<3).map { ReminderHistory(id: "earlier.\($0)", sentAt: F.at(8, 9 + $0)) }
        let plan = F.plan(me: F.kim, weeks: [everyNight], history: sent, now: F.at(8, 12))
        #expect(plan.count == 2)
    }

    @Test func nextWeekHasItsOwnBudget() {
        let next = F.week((15...21).map { F.night($0) }, start: 15)
        let sent = (0..<5).map { ReminderHistory(id: "earlier.\($0)", sentAt: F.at(8, 9 + $0)) }
        // Saturday: this week's used up, and only next week's first nights are within the horizon.
        let plan = F.plan(me: F.kim, weeks: [everyNight, next], history: sent, now: F.at(14, 8))
        #expect(plan.map(\.fireAt) == [15, 16, 17, 18, 19].map { F.at($0, 19) })
    }

    @Test func prepOutranksARatingPromptWhenItRunsShort() {
        var settings = F.settings
        settings.notificationPreset = .light
        let steps = (1...9).map { (hours: Int) in PrepStep(step: "Step \(hours)", leadHours: hours) }
        #expect(F.of(.prep, F.plan(settings: settings, weeks: [F.week([F.night(14, steps: steps)])])).count == 8, "Light's adult budget")

        settings.notificationPreset = .balanced
        let night = F.night(9, steps: (1...9).map { (hours: Int) in PrepStep(step: "Step \(hours)", leadHours: hours) })
        let dinners = F.week([night] + (10...14).map { F.night($0, steps: (1...2).map { (hours: Int) in PrepStep(step: "Prep \(hours)", leadHours: hours) }) })
        let plan = F.plan(settings: settings, weeks: [dinners])
        #expect(F.of(.prep, plan).count == 12)
        #expect(F.of(.afterDinner, plan).isEmpty, "twelve prep steps come first")
    }

    @Test func aSnoozeDoesntCostAnotherOne() {
        let weeks = [F.week([F.night(9, steps: [F.thaw])])]
        var settings = F.settings
        settings.notificationPreset = .light
        let id = F.of(.prep, F.plan(settings: settings, weeks: [F.week([F.night(9, steps: [F.thaw])])], now: F.at(7, 8)))
        #expect(id.count == 1)
        let night = weeks[0].nights[0]
        let key = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        let sent = (0..<7).map { ReminderHistory(id: "earlier.\($0)", sentAt: F.at(8, 1 + $0)) }
            + [ReminderHistory(id: key, sentAt: F.at(8, 18), respondedAt: F.at(8, 18, 5), snoozedUntil: F.at(8, 19, 5))]
        let plan = F.plan(settings: settings, weeks: weeks, history: sent, now: F.at(8, 18, 10))
        #expect(plan.contains { $0.id == key && $0.fireAt == F.at(8, 19, 5) }, "the eighth is the one already sent")
    }

    @Test func allergyRemindersDontExistToBeDropped() {
        #expect(Set(ReminderKind.allCases) == [.timeToPlan, .prep, .afterDinner],
                "if a safety reminder joins these, it must be exempt from the budget")
    }
}

@Suite struct ReminderQuietHoursTests {
    @Test func aPrepReminderBeforeDawnMovesToTheEveningBefore() throws {
        // Marinate 13 hours before Tuesday's 6pm is 5am, in quiet hours, so it goes Monday evening: tomorrow, by then.
        let weeks = [F.week([F.night(10, steps: [PrepStep(step: "Marinate", leadHours: 13)])])]
        let reminder = try #require(F.of(.prep, F.plan(weeks: weeks)).first)
        #expect(reminder.fireAt == F.at(9, 20, 45))
        #expect(reminder.title == "Dinner tomorrow")
    }

    @Test func aMovedLunchtimeDinnerSaysTomorrowToo() throws {
        // Saturday at 2pm, 8 hours back is 6am, so Friday evening.
        var night = F.night(14, steps: [PrepStep(step: "Marinate", leadHours: 8)])
        night.dinnerTime = "14:00"
        let reminder = try #require(F.of(.prep, F.plan(weeks: [F.week([night])])).first)
        #expect(reminder.fireAt == F.at(13, 20, 45))
        #expect(reminder.title == "Dinner tomorrow")
    }

    @Test func aMoveAcrossAnotherDayNamesTheNight() throws {
        // Wednesday's 6pm less 37 hours is Tuesday 5am, so Monday evening.
        let weeks = [F.week([F.night(11, steps: [PrepStep(step: "Marinate", leadHours: 37)])])]
        let reminder = try #require(F.of(.prep, F.plan(weeks: weeks)).first)
        #expect(reminder.fireAt == F.at(9, 20, 45))
        #expect(reminder.title == "Dinner on Wednesday")
    }

    @Test func aFollowUpSaysTheDayFromItsOwnTime() throws {
        var settings = F.settings
        settings.notificationPreset = .engaged
        // Tuesday 6pm less 20 hours is 10pm Monday, so 8:45pm; the follow-up would be 9:45pm, in quiet hours, and doesn't go.
        // Less 24 hours: 6pm Monday, and 7pm.
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        let both = F.of(.prep, F.plan(settings: settings, weeks: weeks))
        #expect(both.map(\.title) == ["Dinner tomorrow", "Dinner tomorrow"])
    }

    @Test func onceTheEveningHasGoneItWaitsForMorningWhileThereIsTime() throws {
        // Read at 10pm Monday: 7am still leaves 11 of the 13 hours.
        let weeks = [F.week([F.night(10, steps: [PrepStep(step: "Marinate", leadHours: 13)])])]
        let reminder = try #require(F.of(.prep, F.plan(weeks: weeks, now: F.at(9, 22))).first)
        #expect(reminder.fireAt == F.at(10, 7))
        #expect(reminder.title == "Dinner tonight")
    }

    @Test func notWithLessThanHalfTheLeadTimeLeft() {
        // A 7:30am breakfast-for-dinner with a 3-hour lead: 7am leaves half an hour.
        var night = F.night(10, steps: [PrepStep(step: "Soak", leadHours: 3)])
        night.dinnerTime = "07:30"
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])], now: F.at(9, 22))).isEmpty)
        // A 3-hour lead with exactly half left does go.
        night.dinnerTime = "08:30"
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])], now: F.at(9, 22))).map(\.fireAt) == [F.at(10, 7)])
    }

    @Test func aKidsPrepWaitsForTheEndOfSchoolTheSameWay() {
        let teen = Member.fixture(firstName: "Tess", ageGroup: .kid, role: .planner, userID: UUID())
        // Wednesday: 8 hours before 6pm is 10am, in school. Before school has gone at 7:50am, and 3pm leaves 3 of 8: too little.
        let short = [F.week([F.night(11, steps: [PrepStep(step: "Slow cooker", leadHours: 8)], home: [teen])])]
        #expect(F.of(.prep, F.plan(me: teen, members: [teen], weeks: short, now: F.at(11, 7, 50))).isEmpty)
        // Less 5 hours is 1pm: 3pm leaves 3 of 5, so it goes.
        let long = [F.week([F.night(11, steps: [PrepStep(step: "Soak", leadHours: 5)], home: [teen])])]
        #expect(F.of(.prep, F.plan(me: teen, members: [teen], weeks: long, now: F.at(11, 7, 50))).map(\.fireAt) == [F.at(11, 15)])
    }

    @Test func aLateDinnersPromptJustDoesntGo() {
        var night = F.night(10)
        night.dinnerTime = "20:30"
        #expect(F.of(.afterDinner, F.plan(me: F.kim, weeks: [F.week([night])])).isEmpty, "9:30pm: the card's still there")
    }

    @Test func aPromptRightAtTheEdgeOfQuietHours() {
        var night = F.night(10)
        night.dinnerTime = "19:59"
        #expect(!F.of(.afterDinner, F.plan(me: F.ben, weeks: [F.week([night])])).isEmpty)
        night.dinnerTime = "20:00"
        #expect(F.of(.afterDinner, F.plan(me: F.ben, weeks: [F.week([night])])).isEmpty, "9pm is the start of quiet")
    }

    @Test func timeToPlanInQuietHoursWaitsForMorning() {
        var settings = F.settings
        settings.planningTime = "06:30"
        #expect(F.of(.timeToPlan, F.plan(settings: settings, now: F.at(8, 1))).first?.fireAt == F.at(8, 7))
        settings.planningTime = "22:30"
        #expect(F.of(.timeToPlan, F.plan(settings: settings, now: F.at(8, 12))).first?.fireAt == F.at(9, 7))
    }

    @Test func aKidsSchoolHoursAreQuietOnWeekdays() {
        let teen = Member.fixture(firstName: "Tess", ageGroup: .kid, role: .planner, userID: UUID())
        var settings = F.settings
        settings.planningDay = 3
        settings.planningTime = "10:00"
        let weeks: [ReminderWeek] = []
        #expect(F.of(.timeToPlan, F.plan(me: teen, members: [teen], settings: settings, weeks: weeks)).first?.fireAt == F.at(11, 15))
        #expect(F.of(.timeToPlan, F.plan(me: F.ann, settings: settings, weeks: weeks)).first?.fireAt == F.at(11, 10),
                "an adult's aren't")
    }

    @Test func notOnAWeekend() {
        let teen = Member.fixture(firstName: "Tess", ageGroup: .kid, role: .planner, userID: UUID())
        var settings = F.settings
        settings.planningDay = 6
        settings.planningTime = "10:00"
        #expect(F.of(.timeToPlan, F.plan(me: teen, members: [teen], settings: settings)).first?.fireAt == F.at(14, 10))
    }

    @Test func aKidsPrepInSchoolMovesToBeforeSchool() {
        let teen = Member.fixture(firstName: "Tess", ageGroup: .kid, role: .planner, userID: UUID())
        // Wednesday the 11th: 8 hours before 6pm is 10am.
        let weeks = [F.week([F.night(11, steps: [PrepStep(step: "Start the slow cooker", leadHours: 8)], home: [teen])])]
        #expect(F.of(.prep, F.plan(me: teen, members: [teen], weeks: weeks)).first?.fireAt == F.at(11, 7, 45))
    }

    @Test func aSnoozeIsTheirsToAskFor() {
        var settings = F.settings
        settings.notificationPreset = .light
        let night = F.night(9, steps: [PrepStep(step: "Soak", leadHours: 24)])
        let id = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        let history = [ReminderHistory(id: id, sentAt: F.at(8, 18), respondedAt: F.at(8, 20, 30), snoozedUntil: F.at(8, 21, 30))]
        #expect(F.plan(settings: settings, weeks: [F.week([night])], history: history, now: F.at(8, 20, 30))
            .contains { $0.id == id && $0.fireAt == F.at(8, 21, 30) })
    }

    @Test func aSnoozePastDinnerIsNoUse() {
        let night = F.night(9, steps: [PrepStep(step: "Soak", leadHours: 2)])
        let id = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        let history = [ReminderHistory(id: id, sentAt: F.at(9, 16), respondedAt: F.at(9, 17, 30), snoozedUntil: F.at(9, 18, 30))]
        #expect(!F.plan(weeks: [F.week([night])], history: history, now: F.at(9, 17, 30)).contains { $0.id == id })
    }

    @Test func aSnoozeOnADishThatChangedIsDropped() {
        var night = F.night(9, steps: [F.thaw])
        let id = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        night.mealID = UUID()
        let history = [ReminderHistory(id: id, sentAt: F.at(8, 18), respondedAt: F.at(8, 18, 5), snoozedUntil: F.at(8, 19, 5))]
        #expect(!F.plan(weeks: [F.week([night])], history: history, now: F.at(8, 18, 10)).contains { $0.id == id })
    }

    @Test func aSnoozeThatsGoneByIsSpent() {
        let night = F.night(9, steps: [F.thaw])
        let id = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        let history = [ReminderHistory(id: id, sentAt: F.at(8, 18), respondedAt: F.at(8, 18, 5), snoozedUntil: F.at(8, 19, 5))]
        #expect(!F.plan(weeks: [F.week([night])], history: history, now: F.at(8, 19, 30)).contains { $0.id == id })
    }

    @Test func doneMeansDone() {
        let night = F.night(9, steps: [F.thaw])
        let id = ReminderID.prep(me: F.ann.id, night: night.id, meal: F.chili, step: 0)
        let history = [ReminderHistory(id: id, sentAt: nil, respondedAt: F.at(8, 9, 30))]
        #expect(!F.plan(weeks: [F.week([night])], history: history).contains { $0.id == id })
    }
}

@Suite struct ReminderClockTests {
    @Test func aThawAcrossSpringForwardKeepsItsClockTime() throws {
        // Clocks change at 2am Sunday, March 14, 2027. 24 hours before Sunday's dinner is 6pm Saturday by the clock.
        let sunday = CalendarDay(year: 2027, month: 3, day: 14)
        let night = ReminderNight(id: UUID(), date: sunday, mealID: F.chili, prepSteps: [F.thaw].compactMap(ReminderPrep.init),
                                  attendance: [F.ann.id: true])
        let week = ReminderWeek(planID: UUID(), start: sunday, isApproved: true, nights: [night])
        let now = F.at(12, 12, month: 3, year: 2027)
        let reminder = try #require(F.of(.prep, F.plan(weeks: [week], now: now)).first)
        #expect(reminder.fireAt == F.at(13, 18, month: 3, year: 2027))
        #expect(reminder.dinnerAt == F.at(14, 18, month: 3, year: 2027))
    }

    @Test func aPromptAndATimeAcrossFallBackAreOnTheHouseholdsClock() throws {
        // Clocks change at 2am Sunday, November 1, 2026.
        let sunday = F.day(1)
        let night = ReminderNight(id: UUID(), date: sunday, mealID: F.chili,
                                  attendance: [F.ann.id: true])
        let week = ReminderWeek(planID: UUID(), start: sunday, isApproved: true, nights: [night])
        let plan = F.plan(weeks: [week], now: F.at(31, 12, month: 10))
        #expect(F.of(.afterDinner, plan).first?.fireAt == F.at(1, 19))
        let notPlanned = F.plan(now: F.at(31, 12, month: 10))
        #expect(F.of(.timeToPlan, notPlanned).first?.fireAt == F.at(1, 9), "9am by the clock, 10 hours into a 25-hour day")
    }

    @Test func aHouseholdElsewhereUsesItsOwnDayAndClockWhereverThePhoneIs() throws {
        // Tokyo: it's already Monday the 9th there at 10am Sunday in New York, so the 8th is over and the 9th is tonight.
        var settings = F.settings
        settings.timeZone = "Asia/Tokyo"
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let weeks = [F.week([F.night(8), F.night(9)])]
        let reminder = try #require(F.of(.afterDinner, F.plan(settings: settings, weeks: weeks)).first)
        #expect(reminder.fireAt == tokyo.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 19)))
        #expect(F.of(.afterDinner, F.plan(settings: settings, weeks: weeks)).count == 1)
    }

    @Test func withNoSavedZoneThePromptIsOnTheCardsClock() throws {
        var settings = F.settings
        settings.timeZone = nil
        let night = F.night(10)
        let reminder = try #require(F.of(.afterDinner, F.plan(settings: settings, weeks: [F.week([night])])).first)
        let card = WeekNight(id: night.id, date: night.date, effort: .normal, dinnerTime: nil, mealID: night.mealID,
                             mealName: nil, quickPick: nil, locked: false, attendance: night.attendance)
        #expect(reminder.fireAt == DinnerPrompts.promptTime(card, defaultDinnerTime: settings.dinnerTime,
                                                            calendar: DinnerPrompts.calendar(for: settings)))
    }

    @Test func aWeekdayIsInTheReadersLanguage() {
        let title = ReminderText.prepTitle(night: F.day(13), firing: F.at(9, 18), calendar: F.calendar,
                                           locale: Locale(identifier: "fr_FR"))
        #expect(title.contains("vendredi"), "\(title)")
    }

    @Test func quietHoursAreTheHouseholdsToo() {
        var settings = F.settings
        settings.timeZone = "America/Los_Angeles"
        var night = F.night(10)
        night.dinnerTime = "18:00"
        // 7pm in Los Angeles is 10pm in New York, quiet there, but it's the household's clock that counts.
        #expect(!F.of(.afterDinner, F.plan(settings: settings, weeks: [F.week([night])])).isEmpty)
    }

    @Test func aBadDinnerTimeRemindsNobody() {
        var night = F.night(10, steps: [F.thaw])
        night.dinnerTime = "soon"
        #expect(F.of(.prep, F.plan(weeks: [F.week([night])])).isEmpty)
        #expect(F.of(.afterDinner, F.plan(weeks: [F.week([night])])).isEmpty)
    }
}

@Suite struct ReminderStaleDataTests {
    private let weeks = [F.week([F.night(10, steps: [F.thaw])])]

    @Test func withoutAReadThereIsNothingToGoOn() {
        var inputs = F.inputs(weeks: weeks)
        inputs.snapshot = nil
        #expect(NotificationPlanner.plan(inputs).isEmpty)
    }

    @Test func aReadOlderThanTwoDaysPlansNothing() {
        let plan = { (age: TimeInterval) in
            F.plan(weeks: self.weeks, now: F.at(8, 10), pulledAt: F.at(8, 10).addingTimeInterval(-age))
        }
        #expect(!plan(47 * 60 * 60).isEmpty)
        #expect(plan(49 * 60 * 60).isEmpty, "including Time to plan: it can't know the week isn't approved")
    }

    @Test func nothingGoesOutTooLongAfterTheRead() {
        let later = F.week((15...18).map { F.night($0) }, start: 15)
        let plan = F.of(.afterDinner, F.plan(weeks: [later]))
        // Read at 10am on the 8th: eight days runs to 10am on the 16th.
        #expect(plan.map(\.fireAt) == [F.at(15, 19)])
    }

    @Test func aHouseholdStillOnboardingGetsNothing() {
        var settings = F.settings
        settings.onboarded = false
        #expect(F.plan(settings: settings, weeks: weeks).isEmpty)
    }

    @Test func someoneRemovedGetsNothing() {
        let removed = Member.fixture(id: F.ann.id, firstName: "Ann", role: .planner, status: .removed, userID: F.ann.userID)
        #expect(F.plan(me: removed, members: [removed], weeks: weeks).isEmpty)
    }
}

@Suite struct ReminderPlanShapeTests {
    private var busy: [ReminderWeek] {
        let steps = (1...5).map { (hours: Int) in PrepStep(step: "Step \(hours)", leadHours: hours) }
        return [F.week((8...14).map { F.night($0, steps: steps) })]
    }

    @Test func sameInputsSamePlan() {
        let input = F.inputs(weeks: busy)
        #expect(NotificationPlanner.plan(input) == NotificationPlanner.plan(input))
    }

    @Test func itsInTimeOrder() {
        let times = F.plan(weeks: busy).map(\.fireAt)
        #expect(!times.isEmpty)
        #expect(times == times.sorted())
    }

    @Test func aBudgetTieBreaksTheSameWayEveryTime() {
        let same = (1...20).map { _ in PrepStep(step: "Same time", leadHours: 3) }
        let weeks = [F.week([F.night(10, steps: same)])]
        let first = F.plan(weeks: weeks)
        #expect(F.of(.prep, first).count == 12)
        #expect(first == F.plan(weeks: weeks))
    }

    @Test func itStaysWellUnderIOSsLimitWhateverTheBudget() {
        // Nothing sent, and more steps than any budget.
        var settings = F.settings
        settings.notificationPreset = .engaged
        let two = busy + [F.week((15...16).map { F.night($0, steps: (1...30).map { (hours: Int) in PrepStep(step: "Step \(hours)", leadHours: hours) }) }, start: 15)]
        let plan = F.plan(settings: settings, weeks: two)
        #expect(plan.count == 32, "two weeks at Engaged's budget: the most there can be, with room for cook timers under 64")
    }

    @Test func everyIdentifierIsOursAndCarriesThePerson() {
        let weeks = [F.week([F.night(10, steps: [F.thaw])])]
        let plan = F.plan(weeks: weeks)
        #expect(plan.count == 3)
        for reminder in plan {
            #expect(ReminderID.isReminder(reminder.id))
            #expect(reminder.id.contains(F.ann.id.uuidString))
        }
        #expect(!ReminderID.isReminder(UUID().uuidString), "a cook-mode timer's identifier")
    }

    @Test func aFollowUpKnowsItsBase() {
        let id = ReminderID.afterDinner(me: UUID(), night: UUID(), meal: UUID())
        #expect(ReminderID.base(of: ReminderID.followUp(of: id)) == id)
        #expect(ReminderID.base(of: id) == id)
    }
}

/// Every word on a lock screen is one of ours. Text is built from fixed strings and the day, whatever the family typed.
@Suite struct ReminderLockScreenTests {
    private var engaged: HouseholdSettings {
        var settings = F.settings
        settings.notificationPreset = .engaged
        return settings
    }

    /// Everything a plan could put on a lock screen, follow-ups included.
    private func words(step: String) -> [String] {
        let weeks = [F.week([F.night(10, steps: [PrepStep(step: step, leadHours: 24)])])]
        return F.plan(settings: engaged, weeks: weeks).flatMap { [$0.title, $0.body] }
    }

    /// A dish's name can't make a difference: `ReminderNight` doesn't have one, so the planner never sees it.
    @Test func aStepsOwnWordsMakeNoDifference() {
        let plain = words(step: "Soak")
        #expect(plain.count >= 6, "prep, its follow-up, and the prompt")
        for step in ["Move the beef to the fridge", "Make Kim's without milk, she's allergic", "Nora's dairy-free lasagna", "ノラ用", ""] {
            #expect(words(step: step) == plain, "\(step)")
        }
    }

    @Test func theWordsAreExactlyTheseAndNoOthers() throws {
        let fixed: Set<String> = ["Dinner tonight", "Dinner tomorrow", "Time to thaw what's for dinner.", "Time to start the marinade.",
                                  "Time to start the slow cooker.", "Time to start prep.", "How was dinner?", "Tap to rate dinner.",
                                  "Time to plan the week", "Foon can draft it in a tap, and you can change any night."]
        let steps = ["Thaw it", "Marinate it", "Start the slow cooker", "Kim's without milk"]
        let night = F.night(10, steps: steps.map { PrepStep(step: $0, leadHours: 20) })
        for reminder in F.plan(settings: engaged, weeks: [F.week([night])]) {
            #expect(fixed.contains(reminder.title), "\(reminder.title)")
            #expect(fixed.contains(reminder.body), "\(reminder.body)")
        }
    }

    @Test func aKnownKindOfStepSaysSoInFixedWords() throws {
        let expected = [
            "Thaw the beef for Kim": "Time to thaw what's for dinner.",
            "DEFROST the chicken": "Time to thaw what's for dinner.",
            "Marinate Nora's portion": "Time to start the marinade.",
            "Start the slow cooker": "Time to start the slow cooker.",
            "Fill the crock-pot": "Time to start the slow cooker."
        ]
        for (step, body) in expected {
            let weeks = [F.week([F.night(10, steps: [PrepStep(step: step, leadHours: 24)])])]
            #expect(try #require(F.of(.prep, F.plan(weeks: weeks)).first).body == body, "\(step)")
        }
    }

    @Test func theTitleSaysTheDayInFixedWords() {
        let weeks = [F.week([F.night(8, steps: [PrepStep(step: "Soak", leadHours: 4)]),
                             F.night(11, steps: [PrepStep(step: "Soak", leadHours: 24)]),
                             F.night(13, steps: [PrepStep(step: "Soak", leadHours: 96)])])]
        #expect(F.of(.prep, F.plan(weeks: weeks)).map(\.title) == ["Dinner tonight", "Dinner on Friday", "Dinner tomorrow"])
    }

    @Test func nothingNamesWhoIsOut() {
        let night = F.night(10, steps: [F.thaw], home: [F.ann, F.kim], out: [F.ben])
        for reminder in F.plan(weeks: [F.week([night])]) {
            for name in ["Ben", "Ann", "Kim"] {
                #expect(!reminder.title.contains(name))
                #expect(!reminder.body.contains(name))
            }
        }
    }

    @Test func aKidsPromptIsTheSameFixedWords() throws {
        let reminder = try #require(F.plan(me: F.kim, weeks: [F.week([F.night(10)])]).first)
        #expect(reminder.title == "How was dinner?")
        #expect(reminder.body == "Tap to rate dinner.")
    }
}
