import Foundation
import Testing
@testable import Foon

struct DinnerPromptsTests {
    private let me = UUID()
    private let kid = UUID()
    private let chili = UUID()
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private let monday = CalendarDay(year: 2026, month: 11, day: 2)

    private func night(_ day: CalendarDay, meal: UUID? = nil, quickPick: QuickPick? = nil, home: [UUID: Bool] = [:],
                       dinnerTime: String? = "18:00:00") -> WeekNight {
        WeekNight(id: UUID(), date: day, effort: .normal, dinnerTime: dinnerTime, mealID: meal,
                  mealName: meal == nil ? nil : "Chili", quickPick: quickPick, locked: false, attendance: home)
    }

    private func at(_ day: CalendarDay, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day.date(in: calendar))!
    }

    private func due(_ nights: [WeekNight], logs: [DinnerLog] = [], now: Date) -> [UUID] {
        DinnerPrompts.due(nights: nights, logs: logs, me: me, defaultDinnerTime: "18:00", now: now, calendar: calendar)
            .map(\.night.id)
    }

    @Test func showsFromAnHourAfterDinnerUntilTheNextEvening() {
        let monday = night(monday, meal: chili, home: [me: true])
        #expect(due([monday], now: at(self.monday, 18, 59)).isEmpty, "not during dinner")
        #expect(due([monday], now: at(self.monday, 19)) == [monday.id])
        #expect(due([monday], now: at(self.monday.adding(days: 1), 8)) == [monday.id], "the missed card, next morning")
        #expect(due([monday], now: at(self.monday.adding(days: 1), 19)).isEmpty, "gone by the next evening")
    }

    @Test func theNextEveningIsDinnerTimeEvenAcrossADaylightSavingChange() {
        // Saturday Oct 31, 2026 18:00; clocks go back early Sunday Nov 1, so the next evening is 25 hours later.
        let saturday = CalendarDay(year: 2026, month: 10, day: 31)
        let night = night(saturday, meal: chili, home: [me: true])
        #expect(due([night], now: at(saturday.adding(days: 1), 18, 30)) == [night.id], "still open before 7pm Sunday")
        #expect(due([night], now: at(saturday.adding(days: 1), 19)).isEmpty, "gone at 7pm Sunday")
    }

    @Test func dishNamesStartWithACapital() {
        let night = WeekNight(id: UUID(), date: monday, effort: .normal, dinnerTime: nil, mealID: chili,
                              mealName: "chili mac", quickPick: nil, locked: false, attendance: [:])
        #expect(DinnerPrompts.Prompt(night: night, log: nil).dishName == "Chili mac")
    }

    @Test func usesTheHouseholdDinnerTimeWhenTheNightHasNone() {
        let monday = night(monday, meal: chili, home: [me: true], dinnerTime: nil)
        #expect(DinnerPrompts.due(nights: [monday], logs: [], me: me, defaultDinnerTime: "17:30",
                                  now: at(self.monday, 18, 30), calendar: calendar).count == 1)
    }

    @Test func onlyForADishYouWereHomeForAndHaventRated() {
        let away = night(monday, meal: chili, home: [me: false])
        let unknown = night(monday, meal: chili)
        let takeout = night(monday, quickPick: .takeout, home: [me: true])
        let empty = night(monday, home: [me: true])
        #expect(due([away, unknown, takeout, empty], now: at(monday, 20)).isEmpty)

        let dinner = night(monday, meal: chili, home: [me: true])
        let rated = DinnerLog(id: UUID(), nightID: dinner.id, date: monday, mealID: chili, mealName: "Chili",
                              quickPick: nil, reactions: [Reaction(memberID: me, kind: .good, offTonight: false, createdAt: .now)])
        #expect(due([dinner], logs: [rated], now: at(monday, 20)).isEmpty)
        let ratedByKidOnly = DinnerLog(id: rated.id, nightID: dinner.id, date: monday, mealID: chili, mealName: "Chili",
                                       quickPick: nil, reactions: [Reaction(memberID: kid, kind: .good, offTonight: false, createdAt: .now)])
        #expect(due([dinner], logs: [ratedByKidOnly], now: at(monday, 20)) == [dinner.id])
    }

    @Test func whatWasActuallyEatenWins() {
        let planned = night(monday, meal: chili, home: [me: true])
        let ateOut = DinnerLog(id: UUID(), nightID: planned.id, date: monday, mealID: nil, mealName: nil,
                               quickPick: .eatOut)
        #expect(due([planned], logs: [ateOut], now: at(monday, 20)).isEmpty, "they ate out instead: nothing to rate")

        let empty = night(monday, home: [me: true])
        let tacos = DinnerLog(id: UUID(), nightID: empty.id, date: monday, mealID: UUID(), mealName: "Tacos",
                              quickPick: nil)
        let prompts = DinnerPrompts.due(nights: [empty], logs: [tacos], me: me, defaultDinnerTime: "18:00",
                                        now: at(monday, 20), calendar: calendar)
        #expect(prompts.first?.dishName == "Tacos", "asked about what they had")
    }

    @Test func theFirstResponderGetsLeftoversAndWhoCooked() {
        let dinner = night(monday, meal: chili, home: [me: true, kid: false])
        let mine = DinnerLog(id: UUID(), nightID: dinner.id, date: monday, mealID: chili, mealName: "Chili",
                             quickPick: nil, confirmedByMemberID: me)
        func extras(_ log: DinnerLog) -> Int {
            DinnerPrompts.extras(nights: [dinner], logs: [log], me: me, defaultDinnerTime: "18:00", now: at(monday, 20),
                                 calendar: calendar).count
        }
        #expect(extras(mine) == 1)
        #expect(extras(DinnerLog(id: mine.id, nightID: dinner.id, date: monday, mealID: chili, mealName: "Chili",
                                 quickPick: nil, leftovers: false, confirmedByMemberID: me)) == 0, "already answered")
        #expect(extras(DinnerLog(id: mine.id, nightID: dinner.id, date: monday, mealID: chili, mealName: "Chili",
                                 quickPick: nil, confirmedByMemberID: kid)) == 0, "someone else answered first")
        #expect(DinnerPrompts.expectsLeftovers(dinner), "the kid was out, so there's probably some left")
        #expect(!DinnerPrompts.expectsLeftovers(night(monday, meal: chili, home: [me: true])))
    }

    @Test func passingThePhoneCoversYouAndProfilesWithoutAccounts() {
        let ann = Member.fixture(firstName: "Ann", userID: UUID())
        let ben = Member.fixture(firstName: "Ben", userID: UUID())
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        #expect(DinnerPrompts.raters(home: [ann, ben, nora], me: ann.id).map(\.firstName) == ["Ann", "Nora"])
    }
}
