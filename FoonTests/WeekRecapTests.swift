import Foundation
import Testing
@testable import Foon

private typealias F = PlannerFixture

/// The weekly recap (docs/spec.md → Weekly recap): which week, what it says, and its one notification on Engaged.
struct WeekRecapTests {
    private let ben = Member.fixture(firstName: "Ben")
    private let maya = Member.fixture(firstName: "Maya", ageGroup: .kid)
    private let gone = Member.fixture(firstName: "Lou", status: .removed)
    private let lastWeek = F.day(1)

    private func facts(logged: Int = 5, cooks: [UUID] = [], top: String? = nil,
                       forgotten: String? = nil) -> WeekRecapFacts {
        WeekRecapFacts(logged: logged, cooks: cooks,
                       topDish: top.map { WeekRecapFacts.Dish(id: UUID(), name: $0) },
                       forgottenFavorite: forgotten.map { WeekRecapFacts.Dish(id: UUID(), name: $0) })
    }

    private func recap(_ facts: WeekRecapFacts,
                       stats: FamilyStats = FamilyStats(dinners: 6, dishes: 5, weeksPlanned: 1),
                       settings: HouseholdSettings = F.settings) -> WeekRecap? {
        WeekRecap(weekStart: lastWeek, facts: facts, stats: stats, members: [ben, maya, gone], settings: settings,
                  calendar: F.calendar)
    }

    // MARK: - Which week

    @Test func itsAboutLastWeekForThreeDaysAfterItEnds() {
        // The fixture's weeks start on Sunday: Nov 1 to 7 ended on Saturday.
        let week = { (day: Int) in WeekRecap.week(today: F.day(day), weekStart: 7, calendar: F.calendar) }
        #expect(week(7) == nil, "not while it's still going")
        #expect(week(8)?.start == F.day(1))
        #expect(week(8)?.end == F.day(7))
        #expect(week(10)?.start == F.day(1), "the third day")
        #expect(week(11) == nil, "gone on the fourth")
    }

    @Test func aWeekStartingMondayEndsOnSunday() {
        let week = WeekRecap.week(today: F.day(9), weekStart: 1, calendar: F.calendar)
        #expect(week?.start == F.day(2))
        #expect(week?.end == F.day(8))
    }

    // MARK: - When there's nothing to say

    @Test func nothingWhenNothingWasLogged() {
        #expect(recap(facts(logged: 0)) == nil, "not approved, or no dinners logged")
        #expect(recap(facts(), stats: FamilyStats()) == nil, "no dinners planned together")
    }

    @Test func nothingForAWeekAllAway() {
        var settings = F.settings
        settings.awayDates = [AwayDates(from: F.day(1), to: F.day(7))]
        #expect(recap(facts(), settings: settings) == nil)
        settings.awayDates = [AwayDates(from: F.day(1), to: F.day(6))]
        #expect(recap(facts(), settings: settings) != nil, "partly away still had dinners")
    }

    // MARK: - The lines

    @Test func everyLineInOrderWhenThereIsSomethingToSay() throws {
        let stats = FamilyStats(dinners: 6, dishes: 5, ideas: 2, atTable: 5, weeksPlanned: 1)
        let everything = facts(cooks: [maya.id, ben.id], top: "Chili", forgotten: "Pot roast")
        let full = try #require(recap(everything, stats: stats))
        #expect(full.lines == [
            .stat(.dinners(6)), .thanks(["Maya", "Ben"]), .topDish("Chili"), .forgottenFavorite("Pot roast"),
            .stat(.ideas(2, of: 5)), .stat(.atTable(5)), .stat(.timeSaved(minutes: 30))
        ])
        #expect(full.estimateNote == stats.estimateNote)
    }

    @Test func linesWithNothingToSayAreLeftOut() throws {
        let bare = try #require(recap(facts(), stats: FamilyStats(dinners: 3, dishes: 3)))
        #expect(bare.lines == [.stat(.dinners(3))])
        #expect(bare.estimateNote == nil)
    }

    @Test func thanksKeepsTheOrderTheyCookedInAndSkipsWhoeverLeft() throws {
        let thanks = try #require(recap(facts(cooks: [ben.id, gone.id, UUID(), maya.id]))).lines
        #expect(thanks.contains(.thanks(["Ben", "Maya"])), "removed, or not in the family as read: left out")
        let nobody = try #require(recap(facts(cooks: [gone.id]))).lines
        #expect(!nobody.contains { if case .thanks = $0 { true } else { false } })
    }

    @Test func thanksNamesPeopleWithoutCountingOrRanking() {
        let english = Locale(identifier: "en_US")
        #expect(WeekRecap.Line.thanks(["Maya"]).title(locale: english) == "Thanks for cooking, Maya.")
        #expect(WeekRecap.Line.thanks(["Maya", "Ben", "Ann"]).title(locale: english)
            == "Thanks for cooking, Maya, Ben, and Ann.")
    }

    @Test func theDishLinesAreAboutTheFood() {
        let english = Locale(identifier: "en_US")
        #expect(WeekRecap.Line.topDish("Chili").title(locale: english) == "The week's hit: Chili")
        #expect(WeekRecap.Line.forgottenFavorite("Pot roast").title(locale: english)
            == "A favorite you haven't had in a while: Pot roast")
    }

    @Test func decodesTheServersFacts() throws {
        let cook = UUID(), dish = UUID()
        let json = Data("""
        {"logged": 4, "cooks": ["\(cook.uuidString)"], "top_dish": {"meal_id": "\(dish.uuidString)", "name": "Chili"},
         "forgotten_favorite": null}
        """.utf8)
        let decoded = try JSONDecoder().decode(WeekRecapFacts.self, from: json)
        #expect(decoded == WeekRecapFacts(logged: 4, cooks: [cook],
                                          topDish: WeekRecapFacts.Dish(id: dish, name: "Chili"), forgottenFavorite: nil))
    }

    @Test func dismissingRemembersThatWeekOnly() {
        let household = UUID()
        let key = WeekRecap.dismissalKey(household: household, week: F.day(1))
        #expect(key == WeekRecap.dismissalKey(household: household, week: F.day(1)))
        #expect(key != WeekRecap.dismissalKey(household: household, week: F.day(8)))
        #expect(key != WeekRecap.dismissalKey(household: UUID(), week: F.day(1)))
    }
}

/// Loading for This Week: last week's facts and counts, only while the card can show.
@MainActor
struct WeekRecapStoreTests {
    /// A Monday: the household's weeks start on Sunday, so last week was Nov 1 to 7.
    private let monday = CalendarDay(year: 2026, month: 11, day: 9)

    private func client(fails: Bool = false) -> HouseholdClient {
        var client = HouseholdClient.preview()
        client.weekRecap = { _, from, to in
            if fails { throw URLError(.notConnectedToInternet) }
            #expect(from == CalendarDay(year: 2026, month: 11, day: 1))
            #expect(to == CalendarDay(year: 2026, month: 11, day: 7))
            return .sample()
        }
        return client
    }

    @Test func itLoadsLastWeekInTheDaysAfterIt() async {
        let store = WeekRecapStore()
        await store.load(client: client(), household: .sample, members: Member.sampleFamily, today: monday)
        #expect(store.recap?.weekStart == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(store.recap?.lines.contains(.topDish("Sheet-pan chicken")) == true)
    }

    @Test func itsGoneOnceTheThreeDaysAreUp() async {
        let store = WeekRecapStore()
        await store.load(client: client(), household: .sample, members: Member.sampleFamily, today: monday)
        await store.load(client: client(), household: .sample, members: Member.sampleFamily,
                         today: monday.adding(days: 2))
        #expect(store.recap == nil, "Wednesday is the fourth day")
    }

    @Test func aFailedLoadLeavesItOut() async {
        let store = WeekRecapStore()
        await store.load(client: client(fails: true), household: .sample, members: Member.sampleFamily, today: monday)
        #expect(store.recap == nil)
    }
}

/// "Your week of dinners is ready.", on Engaged only, the morning after the week.
struct WeekRecapReminderTests {
    private var engaged: HouseholdSettings {
        var settings = F.settings
        settings.notificationPreset = .engaged
        return settings
    }

    private func logged(_ day: Int) -> ReminderNight {
        var night = F.night(day)
        night.hasLog = true
        night.loggedMealID = F.chili
        return night
    }

    private func plan(me: Member = F.ann, settings: HouseholdSettings? = nil, weeks: [ReminderWeek],
                      lastWeek: ReminderWeek? = nil, now: Date = F.at(7, 12, month: 11)) -> [PlannedReminder] {
        var inputs = F.inputs(me: me, settings: settings ?? engaged, weeks: weeks, now: now)
        inputs.snapshot?.lastWeek = lastWeek
        return F.of(.weeklyRecap, NotificationPlanner.plan(inputs))
    }

    /// Nov 1 to 7, the week ending Saturday, read on Saturday.
    private let endingWeek: ReminderWeek = {
        let nights = (1...7).map { day -> ReminderNight in
            var night = F.night(day)
            night.hasLog = true
            night.loggedMealID = F.chili
            return night
        }
        return F.week(nights, start: 1)
    }()

    @Test func itGoesAtTenTheMorningAfterTheWeekAndOpensThisWeek() throws {
        let recap = try #require(plan(weeks: [endingWeek]).first)
        #expect(recap.fireAt == F.at(8, 10))
        #expect(recap.route == .week(F.day(8)))
        #expect(recap.title == "Your week of dinners is ready.")
        #expect(recap.body == "Tap to see it.")
        #expect(recap.nightID == nil)
        #expect(ReminderKind.weeklyRecap.rawValue == "weekly_recap")
    }

    @Test func itsStillThereTheMorningItGoesOnceTheWeekIsLastWeek() throws {
        // Sunday at 8am the snapshot's weeks are this one and next; the week it's about is held apart.
        let recap = plan(weeks: [F.week([F.night(9)], start: 8)], lastWeek: endingWeek, now: F.at(8, 8))
        #expect(recap.first?.fireAt == F.at(8, 10))
    }

    @Test func onlyOnEngagedAndTheirOwnPresetCounts() {
        #expect(plan(settings: F.settings, weeks: [endingWeek]).isEmpty, "Balanced doesn't send it")
        var light = F.ann
        light.notificationPrefs = NotificationPrefs(preset: .light)
        #expect(plan(me: light, weeks: [endingWeek]).isEmpty, "their own Light wins over an Engaged family")
        var keen = F.ben
        keen.notificationPrefs = NotificationPrefs(preset: .engaged)
        #expect(!plan(me: keen, settings: F.settings, weeks: [endingWeek]).isEmpty,
                "their own Engaged in a Balanced family")
    }

    @Test func kidsGetItTooButAfterSchool() throws {
        // A Monday-start week ends Sunday the 8th; Monday the 9th at 10am is in school hours.
        var settings = engaged
        settings.weekStart = 1
        let week = F.week((2...8).map(logged), start: 2)
        let recap = try #require(plan(me: F.kim, settings: settings, weeks: [week], now: F.at(8, 12)).first)
        #expect(recap.fireAt == F.at(9, 15), "moved to the end of the quiet stretch")
        #expect(try #require(plan(me: F.ann, settings: settings, weeks: [week], now: F.at(8, 12)).first).fireAt
            == F.at(9, 10))
    }

    @Test func nothingForADraftAnAwayWeekOrOneWithNothingLogged() {
        #expect(plan(weeks: [F.week((1...7).map(logged), start: 1, approved: false)]).isEmpty, "not approved")
        #expect(plan(weeks: [F.week((1...7).map { F.night($0) }, start: 1)]).isEmpty, "nothing logged")
        var away = engaged
        away.awayDates = [AwayDates(from: F.day(1), to: F.day(7))]
        #expect(plan(settings: away, weeks: [endingWeek]).isEmpty, "away all week")
    }

    @Test func itNeverFollowsUpAndComesLastInTheBudget() {
        #expect(plan(weeks: [endingWeek]).count == 1)
        for kind in ReminderKind.allCases where kind != .weeklyRecap {
            #expect(kind.budgetOrder < ReminderKind.weeklyRecap.budgetOrder)
        }
    }

    @Test func aSnapshotSavedBeforeLastWeekWasKeptStillReads() throws {
        let old = Data(#"{"pulledAt": 0, "weeks": []}"#.utf8)
        let snapshot = try JSONDecoder().decode(ReminderSnapshot.self, from: old)
        #expect(snapshot.lastWeek == nil)
        let kept = ReminderSnapshot(pulledAt: .now, weeks: [], lastWeek: endingWeek)
        let reread = try JSONDecoder().decode(ReminderSnapshot.self, from: JSONEncoder().encode(kept))
        #expect(reread.lastWeek == endingWeek)
        #expect(kept.applying([CheckInAnswer(nightID: UUID(), memberID: UUID(), home: true)]).lastWeek == endingWeek)
    }
}
