import Foundation
import Testing
@testable import Foon

/// "Your year in dinners" (docs/spec.md → Yearly recap): which year, what it says, and when This Week offers it.
struct YearRecapTests {
    private let ben = Member.fixture(firstName: "Ben")
    private let maya = Member.fixture(firstName: "Maya", ageGroup: .kid)
    private let gone = Member.fixture(firstName: "Lou", status: .removed)
    private let english = Locale(identifier: "en_US")

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    private func dish(_ name: String, _ times: Int) -> YearRecapFacts.Dish {
        YearRecapFacts.Dish(id: UUID(), name: name, times: times)
    }

    private func recap(_ facts: YearRecapFacts) -> YearRecap? {
        YearRecap(year: 2026, facts: facts, members: [ben, maya, gone])
    }

    // MARK: - Which year

    @Test func familyShowsThisYearSoFarExceptTheFirstWeekOfJanuary() {
        #expect(YearRecap.familyYear(today: day(2026, 11, 3)) == 2026)
        #expect(YearRecap.familyYear(today: day(2026, 12, 31)) == 2026)
        #expect(YearRecap.familyYear(today: day(2027, 1, 1)) == 2026, "last year, just ended")
        #expect(YearRecap.familyYear(today: day(2027, 1, 7)) == 2026)
        #expect(YearRecap.familyYear(today: day(2027, 1, 8)) == 2027, "the new year from the 8th")
    }

    @Test func thisWeeksCardIsDueFromDecember26ThroughJanuary7() {
        #expect(YearRecap.cardYear(today: day(2026, 12, 25)) == nil)
        #expect(YearRecap.cardYear(today: day(2026, 12, 26)) == 2026, "the year that's ending")
        #expect(YearRecap.cardYear(today: day(2026, 12, 31)) == 2026)
        #expect(YearRecap.cardYear(today: day(2027, 1, 1)) == 2026, "the year that just ended")
        #expect(YearRecap.cardYear(today: day(2027, 1, 7)) == 2026)
        #expect(YearRecap.cardYear(today: day(2027, 1, 8)) == nil)
        #expect(YearRecap.cardYear(today: day(2026, 6, 15)) == nil)
    }

    @Test func theHeadingSaysSoFarWhileTheYearIsGoing() {
        #expect(YearRecap.heading(year: 2026, today: day(2026, 11, 3), locale: english) == "2026 so far")
        #expect(YearRecap.heading(year: 2026, today: day(2027, 1, 3), locale: english) == "2026")
    }

    @Test func dismissingRemembersThatYearOnly() {
        let household = UUID()
        let key = YearRecap.dismissalKey(household: household, year: 2026)
        #expect(key == YearRecap.dismissalKey(household: household, year: 2026))
        #expect(key != YearRecap.dismissalKey(household: household, year: 2027))
        #expect(key != YearRecap.dismissalKey(household: UUID(), year: 2026))
        #expect(key != WeekRecap.dismissalKey(household: household, week: day(2026, 1, 1)), "not a week's key")
    }

    // MARK: - What it says

    @Test func nothingForAYearWithNoDinnersLogged() {
        #expect(recap(YearRecapFacts()) == nil)
        #expect(recap(YearRecapFacts(logged: 0, stats: FamilyStats(dinners: 3, atTable: 3))) == nil)
    }

    @Test func everyLineInOrderWhenThereIsSomethingToSay() throws {
        let stats = FamilyStats(dinners: 200, dishes: 180, ideas: 40, cookedByOthers: 30, atTable: 170,
                                newDishes: 24, weeksPlanned: 40)
        let top = [dish("Tacos", 22), dish("Chili", 15), dish("Pie", 9)]
        let facts = YearRecapFacts(logged: 190, stats: stats, topDishes: top, cooks: [maya.id, ben.id],
                                   tried: [ben.id])
        let full = try #require(recap(facts))
        #expect(full.lines == [
            .stat(.atTable(170)),
            .topDishes([.init(name: "Tacos", times: 22), .init(name: "Chili", times: 15),
                        .init(name: "Pie", times: 9)]),
            .thanks(["Maya", "Ben"]),
            .stat(.newDishes(24)),
            .triedNew(["Ben"]),
            .stat(.ideas(40, of: 180)),
            .stat(.timeSaved(minutes: 1200))
        ], "dinners planned and the usual cook's count stay on the month's card")
        #expect(full.estimateNote == stats.estimateNote)
        #expect(full.year == 2026)
    }

    @Test func linesWithNothingToSayAreLeftOut() throws {
        let bare = try #require(recap(YearRecapFacts(logged: 2, stats: FamilyStats(dinners: 2, dishes: 2))))
        #expect(bare.lines.isEmpty, "two dinners out, nobody cooked: logged, but nothing else worth saying")
        #expect(bare.estimateNote == nil)
    }

    @Test func namesKeepTheirOrderAndSkipWhoeverLeft() throws {
        let facts = YearRecapFacts(logged: 5, cooks: [ben.id, gone.id, UUID(), maya.id], tried: [gone.id])
        let lines = try #require(recap(facts)).lines
        #expect(lines == [.thanks(["Ben", "Maya"])], "removed, or not in the family as read: left out")
    }

    @Test func thanksAndTriesNameEveryoneWithoutCounting() {
        #expect(YearRecap.Line.thanks(["Maya"]).title(locale: english) == "Thanks for cooking this year, Maya.")
        #expect(YearRecap.Line.thanks(["Maya", "Ben", "Ann"]).title(locale: english)
            == "Thanks for cooking this year, Maya, Ben, and Ann.")
        #expect(YearRecap.Line.triedNew(["Maya", "Ben"]).title(locale: english)
            == "Tried something new this year: Maya and Ben.")
    }

    @Test func theTopDishesAreAboutTheFood() {
        let top = YearRecap.Line.topDishes([.init(name: "Tacos", times: 22)])
        #expect(top.title(locale: english) == "The year's top dishes")
        #expect(YearRecap.TopDish(name: "Tacos", times: 22).detail == "Made 22 times")
        #expect(YearRecap.TopDish(name: "Pie", times: 1).detail == "Made 1 time", "the catalog's plural")
    }

    @Test func statLinesReadAsTheStatsCardDoes() {
        #expect(YearRecap.Line.stat(.atTable(170)).title(locale: english) == FamilyStats.Line.atTable(170).title)
    }

    // MARK: - Decoding

    @Test func decodesTheServersFacts() throws {
        let cook = UUID(), meal = UUID()
        let json = Data("""
        {"logged": 12, "cooks": ["\(cook.uuidString)"], "tried": [],
         "top_dishes": [{"meal_id": "\(meal.uuidString)", "name": "Tacos", "times": 4}],
         "stats": {"dinners": 14, "dishes": 12, "ideas": 2, "cooked_by_others": 1, "at_table": 11,
                   "new_dishes": 3, "weeks_planned": 2}}
        """.utf8)
        let decoded = try JSONDecoder().decode(YearRecapFacts.self, from: json)
        #expect(decoded == YearRecapFacts(
            logged: 12,
            stats: FamilyStats(dinners: 14, dishes: 12, ideas: 2, cookedByOthers: 1, atTable: 11, newDishes: 3,
                               weeksPlanned: 2),
            topDishes: [YearRecapFacts.Dish(id: meal, name: "Tacos", times: 4)], cooks: [cook], tried: []))
    }

    @Test func decodesWhatItKnowsAndDefaultsTheRest() throws {
        let decoded = try JSONDecoder().decode(YearRecapFacts.self, from: Data(#"{"logged": 3}"#.utf8))
        #expect(decoded == YearRecapFacts(logged: 3), "a server with fewer facts still gives a recap")
    }
}

/// Loading the year: quiet about it, never in the way, and a retry when it fails.
@MainActor
struct YearRecapStoreTests {
    private func client(fails: Bool = false, logged: Int = 6) -> HouseholdClient {
        var client = HouseholdClient.preview()
        client.yearRecap = { _, year in
            if fails { throw URLError(.notConnectedToInternet) }
            #expect(year == 2026)
            return YearRecapFacts(logged: logged, stats: FamilyStats(dinners: logged, atTable: logged))
        }
        return client
    }

    @Test func itLoadsTheYear() async {
        let store = YearRecapStore()
        #expect(store.phase == .loading)
        await store.load(client: client(), householdID: Household.sample.id, year: 2026, members: [])
        #expect(store.recap?.year == 2026)
        #expect(store.recap?.lines == [.stat(.atTable(6))])
    }

    @Test func aYearWithNothingLoggedLoadsAsNothing() async {
        let store = YearRecapStore()
        await store.load(client: client(logged: 0), householdID: Household.sample.id, year: 2026, members: [])
        #expect(store.phase == .loaded(nil))
        #expect(store.recap == nil)
    }

    @Test func aFailureSaysSoUntilARetryWorks() async {
        let store = YearRecapStore()
        await store.load(client: client(fails: true), householdID: Household.sample.id, year: 2026, members: [])
        #expect(store.phase == .failed)
        await store.load(client: client(), householdID: Household.sample.id, year: 2026, members: [])
        #expect(store.recap != nil)
    }

    @Test func aFailedRefreshKeepsWhatShows() async {
        let store = YearRecapStore()
        await store.load(client: client(), householdID: Household.sample.id, year: 2026, members: [])
        await store.load(client: client(fails: true), householdID: Household.sample.id, year: 2026, members: [])
        #expect(store.recap != nil)
    }
}
