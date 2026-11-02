import Foundation
import Synchronization
import Testing
@testable import Foon

struct FamilyStatsTests {
    private let english = Locale(identifier: "en_US")

    @Test func decodesTheServersCounts() throws {
        let json = Data("""
        {"dinners": 12, "dishes": 10, "ideas": 3, "cooked_by_others": 4, "at_table": 9, "new_dishes": 2, "weeks_planned": 4}
        """.utf8)
        let stats = try JSONDecoder().decode(FamilyStats.self, from: json)
        #expect(stats == FamilyStats(dinners: 12, dishes: 10, ideas: 3, cookedByOthers: 4, atTable: 9, newDishes: 2,
                                     weeksPlanned: 4))
    }

    @Test func thirtyMinutesForEachWeekPlanned() {
        #expect(FamilyStats.minutesSavedPerWeekPlanned == 30)
        #expect(FamilyStats(dinners: 1, weeksPlanned: 0).minutesSaved == 0)
        #expect(FamilyStats(dinners: 1, weeksPlanned: 5).minutesSaved == 150)
    }

    @Test func everyLineInOrderWhenThereIsSomethingToSay() {
        #expect(FamilyStats.sample.lines == [
            .dinners(12), .ideas(3, of: 10), .cookedByOthers(4), .atTable(9), .newDishes(2), .timeSaved(minutes: 120)
        ])
    }

    @Test func zeroCountsAreLeftOut() {
        let stats = FamilyStats(dinners: 5, dishes: 4, weeksPlanned: 1)
        #expect(stats.lines == [.dinners(5), .timeSaved(minutes: 30)])
        #expect(FamilyStats(dinners: 2, dishes: 2).lines == [.dinners(2)], "no week planned, no time saved")
    }

    @Test func noDinnersIsTheEmptyStateNotARowOfZeros() {
        // A week can start late last month and be approved before any of this month's nights have a dinner.
        let stats = FamilyStats(weeksPlanned: 1)
        #expect(stats.isEmpty)
        #expect(stats.lines.isEmpty)
        #expect(stats.estimateNote == nil)
        #expect(!FamilyStats(dinners: 1).isEmpty)
    }

    @Test func theEstimateIsLabeledOnlyWhenTimeSavedShows() {
        #expect(FamilyStats(dinners: 3, weeksPlanned: 1).estimateNote?.contains("estimate") == true)
        #expect(FamilyStats(dinners: 3).estimateNote == nil)
    }

    @Test func singularsAndPlurals() {
        #expect(FamilyStats.Line.dinners(1).title == "1 dinner planned together")
        #expect(FamilyStats.Line.dinners(12).title == "12 dinners planned together")
        #expect(FamilyStats.Line.ideas(1, of: 1).title == "1 dinner was someone else's idea")
        #expect(FamilyStats.Line.ideas(1, of: 12).title == "1 of 12 dinners was someone else's idea")
        #expect(FamilyStats.Line.ideas(3, of: 12).title == "3 of 12 dinners were someone else's idea")
        #expect(FamilyStats.Line.cookedByOthers(1).title == "1 night cooked by someone other than the usual cook")
        #expect(FamilyStats.Line.cookedByOthers(4).title == "4 nights cooked by someone other than the usual cook")
        #expect(FamilyStats.Line.atTable(1).title == "1 family dinner at the table")
        #expect(FamilyStats.Line.atTable(9).title == "9 family dinners at the table")
        #expect(FamilyStats.Line.newDishes(1).title == "1 new dish tried")
        #expect(FamilyStats.Line.newDishes(2).title == "2 new dishes tried")
    }

    @Test func timeSavedReadsAsADuration() {
        #expect(FamilyStats.Line.duration(minutes: 30, locale: english) == "30 minutes")
        #expect(FamilyStats.Line.duration(minutes: 120, locale: english) == "2 hours")
        #expect(FamilyStats.Line.duration(minutes: 90, locale: english) == "1 hour, 30 minutes")
        #expect(FamilyStats.Line.timeSaved(minutes: 120).title.hasPrefix("About "))
        #expect(FamilyStats.Line.timeSaved(minutes: 120).title.hasSuffix(" of planning saved"))
    }

    @Test func noLineNamesACook() {
        let titles = FamilyStats.sample.lines.map(\.title).joined(separator: " ")
        for name in Member.sampleFamily.map(\.firstName) {
            #expect(!titles.contains(name))
        }
    }

    @Test func theMonthRunsFromTheFirstThroughToday() {
        let range = FamilyStats.monthToDate(today: CalendarDay(year: 2026, month: 11, day: 17))
        #expect(range.from == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(range.to == CalendarDay(year: 2026, month: 11, day: 17))
        let first = FamilyStats.monthToDate(today: CalendarDay(year: 2027, month: 1, day: 1))
        #expect(first.from == first.to)
    }
}

@MainActor
struct FamilyStatsStoreTests {
    private func household(timeZone: String) -> Household {
        var settings = HouseholdSettings()
        settings.timeZone = timeZone
        return Household(id: Household.sample.id, name: "The Smiths", owner: .previewUser, settings: settings)
    }

    @Test func asksForTheMonthSoFarByTheHouseholdsDay() async {
        // 2026-12-01 03:00 UTC is still November 30 in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_796_094_000)
        let asked = Mutex<[(UUID, CalendarDay, CalendarDay)]>([])
        let home = household(timeZone: "America/Los_Angeles")
        var client = HouseholdClient.fake(myHousehold: { home }, members: { _ in Member.sampleFamily })
        client.familyStats = { id, from, to in
            asked.withLock { $0.append((id, from, to)) }
            return .sample
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadStats(now: now)

        let call = asked.withLock { $0 }
        #expect(call.count == 1)
        #expect(call.first?.0 == home.id)
        #expect(call.first?.1 == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(call.first?.2 == CalendarDay(year: 2026, month: 11, day: 30))
        #expect(store.stats == .sample)
    }

    @Test func aFailedLoadStaysQuietAndKeepsWhatWasShown() async {
        let failing = Mutex(false)
        let home = household(timeZone: "America/New_York")
        var client = HouseholdClient.fake(myHousehold: { home }, members: { _ in Member.sampleFamily })
        client.familyStats = { _, _, _ in
            if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return .sample
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadStats()
        failing.withLock { $0 = true }
        await store.loadStats()

        #expect(store.stats == .sample)
        #expect(store.errorMessage == nil, "the card never puts an error on the Family tab")
    }

    @Test func noHouseholdNoCall() async {
        let calls = Mutex(0)
        var client = HouseholdClient.fake()
        client.familyStats = { _, _, _ in
            calls.withLock { $0 += 1 }
            return .sample
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.loadStats()
        #expect(calls.withLock { $0 } == 0)
        #expect(store.stats == nil)
    }
}

extension FamilyStatsStoreTests {
    @Test func aNewHouseholdDoesNotShowTheOldOnesMonth() async {
        let current = Mutex(household(timeZone: "America/New_York"))
        var client = HouseholdClient.fake(myHousehold: { current.withLock { $0 } }, members: { _ in Member.sampleFamily })
        client.familyStats = { id, _, _ in
            if id == Household.sample.id { return .sample }
            throw URLError(.notConnectedToInternet)
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadStats()
        #expect(store.stats == .sample)

        current.withLock { $0 = Household(id: UUID(), name: "Real family", owner: .previewUser, settings: $0.planningSettings) }
        await store.load()
        await store.loadStats()
        #expect(store.stats == nil)
    }
}
