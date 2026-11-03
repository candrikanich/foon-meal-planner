import Foundation
import Testing
@testable import Foon

private typealias F = PlannerFixture

struct RatingCadenceTests {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func outcome(_ daysAgo: Double, answered: Bool) -> PromptOutcome {
        PromptOutcome(firedAt: start.addingTimeInterval(-daysAgo * day), answered: answered)
    }

    // MARK: - Counting

    @Test func theStreakIsTheLatestUnansweredInARow() {
        #expect(RatingCadence.ignoredStreak([outcome(5, answered: true), outcome(3, answered: false), outcome(2, answered: false),
                                             outcome(1, answered: false)]) == 3)
        #expect(RatingCadence.ignoredStreak([outcome(3, answered: false), outcome(2, answered: false),
                                             outcome(1, answered: true)]) == 0, "answering any one resets it")
        #expect(RatingCadence.ignoredStreak([]) == 0)
    }

    @Test func threeIgnoredInARowGoesWeeklyAndTwoDoesnt() {
        let three = [outcome(3, answered: false), outcome(2, answered: false), outcome(1, answered: false)]
        #expect(RatingCadence().after(three, now: start).weeklySince == start)
        #expect(!RatingCadence().after(Array(three.dropFirst()), now: start).isWeekly)
    }

    @Test func promptsFromBeforeTheyAskedForThemBackDontCount() {
        let back = RatingCadence(weeklySince: nil, offeredBack: false, countsFrom: start.addingTimeInterval(-1.5 * day))
        let three = [outcome(3, answered: false), outcome(2, answered: false), outcome(1, answered: false)]
        #expect(!back.after(three, now: start).isWeekly, "only one of those came after")
    }

    // MARK: - Want these back?

    @Test func wantTheseBackIsOfferedOnceAfterTenDays() {
        let weekly = RatingCadence(weeklySince: start)
        #expect(!weekly.shouldOfferBack(at: start.addingTimeInterval(9 * day)))
        #expect(weekly.shouldOfferBack(at: start.addingTimeInterval(10 * day)))
        #expect(!weekly.keptWeekly().shouldOfferBack(at: start.addingTimeInterval(30 * day)), "Keep it weekly: not again")
        #expect(weekly.keptWeekly().isWeekly)
        #expect(!RatingCadence().shouldOfferBack(at: start), "nothing to offer back while it's each night")
    }

    @Test func yesBringsBackEachNightWithACleanSlate() {
        let later = start.addingTimeInterval(12 * day)
        let back = RatingCadence(weeklySince: start).takenBack(at: later)
        #expect(!back.isWeekly)
        #expect(back.countsFrom == later)
    }

    @Test func itSurvivesBeingSaved() throws {
        let cadence = RatingCadence(weeklySince: start, offeredBack: true, countsFrom: start)
        #expect(try JSONDecoder().decode(RatingCadence.self, from: JSONEncoder().encode(cadence)) == cadence)
    }

    // MARK: - What counts as ignored

    @Test func ignoredMeansNoTapNoRatingAndNotMarkedOut() {
        let me = UUID()
        let nights = (0..<6).map { index in
            ReminderNight(id: UUID(), date: CalendarDay(year: 2026, month: 11, day: 2 + index), attendance: [me: true])
        }
        var rated = nights[2]
        rated.ratedBy = [me]
        var out = nights[3]
        out.attendance[me] = false
        let sent = start.addingTimeInterval(-2 * day)
        func record(_ night: ReminderNight, kind: ReminderKind = .afterDinner, sent: Date? = sent,
                    responded: Date? = nil) -> ReminderRecordSummary {
            ReminderRecordSummary(kind: kind, nightID: night.id, sentAt: sent, respondedAt: responded)
        }
        let records = [
            record(nights[0]),
            record(nights[1], responded: sent),
            record(rated),
            record(out),
            record(nights[4], sent: start.addingTimeInterval(-3600)),
            record(nights[5], kind: .checkIn),
            ReminderRecordSummary(kind: .afterDinner, nightID: UUID(), sentAt: sent, respondedAt: nil)
        ]
        let outcomes = PromptOutcome.outcomes(records, nights: [nights[0], nights[1], rated, out, nights[4], nights[5]],
                                              me: me, now: start)
        #expect(outcomes.map(\.answered) == [false, true, true, true],
                "unanswered; tapped; rated on any phone; said they weren't home. Not an open card, a check-in, or an unread night")
    }

    // MARK: - The plan

    @Test func weeklyMeansOneRoundupInsteadOfEachNight() throws {
        let weeks = [F.week((8...14).map { F.night($0) })]
        var inputs = F.inputs(me: F.kim, weeks: weeks, now: F.at(8, 12))
        #expect(!F.of(.afterDinner, NotificationPlanner.plan(inputs)).isEmpty)
        #expect(F.of(.ratingRoundup, NotificationPlanner.plan(inputs)).isEmpty)

        inputs.cadence = RatingCadence(weeklySince: F.at(7, 12))
        let plan = NotificationPlanner.plan(inputs)
        #expect(F.of(.afterDinner, plan).isEmpty)
        let roundup = try #require(F.of(.ratingRoundup, plan).first)
        #expect(roundup.fireAt == F.at(14, 19, 30), "the week's last evening")
        #expect(roundup.route == .roundup(F.day(8)))
        #expect(roundup.title == "Rate this week's dinners")
    }

    @Test func noRoundupWhenTheresNothingToRate() {
        var rated = (8...14).map { F.night($0) }
        for index in rated.indices { rated[index].ratedBy = [F.kim.id] }
        var inputs = F.inputs(me: F.kim, weeks: [F.week(rated)], now: F.at(8, 12))
        inputs.cadence = RatingCadence(weeklySince: F.at(7, 12))
        #expect(F.of(.ratingRoundup, NotificationPlanner.plan(inputs)).isEmpty)
    }

    @Test func theRoundupOpensThisWeekFromTheLockScreen() {
        let payload = ReminderPayload(route: .roundup(F.day(8)), dinnerAt: nil)
        #expect(ReminderPayload(userInfo: payload.userInfo)?.route == .roundup(F.day(8)))
        #expect(ReminderRoute.roundup(F.day(8)).tab == .week)
    }

    // MARK: - The roundup's list

    @Test func theListIsTheWeeksUnratedDishesOnceTheyreOver() {
        let me = UUID()
        let monday = CalendarDay(year: 2026, month: 11, day: 2)
        func night(_ offset: Int, meal: UUID? = UUID(), quickPick: QuickPick? = nil, home: Bool = true) -> WeekNight {
            WeekNight(id: UUID(), date: monday.adding(days: offset), effort: .normal, dinnerTime: "18:00:00", mealID: meal,
                      mealName: meal == nil ? nil : "Chili", quickPick: quickPick, locked: false, attendance: [me: home])
        }
        let eaten = night(0), away = night(1, home: false), takeout = night(2, meal: nil, quickPick: .takeout)
        let rated = night(3), tonight = night(4)
        let ratedLog = DinnerLog(id: UUID(), nightID: rated.id, date: rated.date, mealID: rated.mealID, mealName: "Chili",
                                 quickPick: nil,
                                 reactions: [Reaction(memberID: me, kind: .good, offTonight: false, createdAt: .now)])
        let now = F.calendar.date(bySettingHour: 18, minute: 30, second: 0, of: monday.adding(days: 4).date(in: F.calendar))!
        let unrated = DinnerPrompts.unrated(nights: [tonight, rated, takeout, away, eaten], logs: [ratedLog], me: me,
                                            defaultDinnerTime: "18:00", now: now, calendar: F.calendar)
        #expect(unrated.map(\.night.id) == [eaten.id], "not away, a quick pick, rated, or tonight before its card opens")
    }
}
