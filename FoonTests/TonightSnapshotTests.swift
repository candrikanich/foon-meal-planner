import Foundation
import Testing
@testable import Foon

/// The Tonight widget's snapshot (#62): what the app writes when the week changes, and when the widget turns over.
@Suite struct TonightSnapshotTests {
    private let household = UUID()
    private let zone = "America/Chicago"
    private let today = CalendarDay(year: 2026, month: 11, day: 4)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func day(_ offset: Int) -> CalendarDay { today.adding(days: offset, calendar: calendar) }

    private func night(_ offset: Int, _ title: String? = nil) -> TonightSnapshot.Night {
        TonightSnapshot.Night(date: day(offset), title: title, isDish: title != nil)
    }

    private func snapshot(_ nights: [TonightSnapshot.Night], household: UUID? = nil) -> TonightSnapshot {
        TonightSnapshot(householdID: household ?? self.household, timeZone: zone, nights: nights)
    }

    @Test func theWeekJustSeenReplacesItsOwnNightsAndKeepsTheOther() {
        let saved = snapshot([night(0, "Tacos"), night(1, "Chili"), night(8, "Pizza")])
        let merged = saved.merging([night(0, "Soup"), night(1)], householdID: household, timeZone: zone, today: today)
        #expect(merged.nights == [night(0, "Soup"), night(1), night(8, "Pizza")])
    }

    @Test func anotherHouseholdsNightsDontStay() {
        let saved = snapshot([night(3, "Tacos")], household: UUID())
        let merged = saved.merging([night(0, "Soup")], householdID: household, timeZone: zone, today: today)
        #expect(merged.householdID == household)
        #expect(merged.nights == [night(0, "Soup")])
    }

    @Test func keepsYesterdayThroughTwoWeeksOut() {
        let incoming = [night(-2, "Old"), night(-1, "Yesterday"), night(13, "Last"), night(14, "Too far")]
        let merged = snapshot([]).merging(incoming, householdID: household, timeZone: zone, today: today)
        #expect(merged.nights.map(\.title) == ["Yesterday", "Last"])
    }

    @Test func turnsOverAtTheHouseholdsMidnight() throws {
        // 11pm in Chicago on the 4th is already the 5th in UTC: tonight is still the 4th.
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23)))
        let saved = snapshot([night(0, "Tacos"), night(2, "Chili")])
        let dates = saved.refreshDates(from: late)
        #expect(dates == [late] + (1...3).map { day($0).date(in: calendar) })
        #expect(dates.map { CalendarDay($0, calendar: calendar) } == [day(0), day(1), day(2), day(3)])
    }

    @Test func nothingAheadMeansNoLaterEntries() {
        let now = day(0).date(in: calendar).addingTimeInterval(3600)
        #expect(snapshot([night(0, "Tacos")]).refreshDates(from: now) == [now])
        #expect(snapshot([]).refreshDates(from: now) == [now])
    }

    @Test func aNightReadsAsThisWeekShowsIt() {
        let away = AwayDates(from: day(2), to: day(3))
        func make(_ offset: Int, meal: String? = nil, pick: QuickPick? = nil) -> TonightSnapshot.Night {
            TonightSnapshot.Night(WeekNight(id: UUID(), date: day(offset), effort: .normal, dinnerTime: "18:30",
                                            mealID: meal == nil ? nil : UUID(), mealName: meal, quickPick: pick,
                                            locked: false, attendance: [:]), awayDates: [away])
        }
        #expect(make(0, meal: "Tacos") == .init(date: day(0), title: "Tacos", isDish: true, dinnerTime: "18:30"))
        #expect(make(1, pick: .takeout) == .init(date: day(1), title: "Takeout", dinnerTime: "18:30"))
        #expect(make(2, meal: "Tacos") == .init(date: day(2), isAway: true))
        #expect(make(4) == .init(date: day(4), dinnerTime: "18:30"))
    }

    @Test func savedAndLoadedFromItsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TonightFile(url: directory.appending(path: "Tonight.json"))
        #expect(file.load() == nil)
        let saved = snapshot([night(0, "Tacos")])
        try file.save(saved)
        #expect(file.load() == saved)
        file.clear()
        #expect(file.load() == nil)
    }
}
