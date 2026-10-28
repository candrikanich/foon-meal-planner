import Foundation
import Testing
@testable import Foon

struct PlanItTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)
    private let tacos = UUID()

    private func night(_ offset: Int, mealID: UUID? = nil, mealName: String? = nil,
                       quickPick: QuickPick? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil, mealID: mealID,
                  mealName: mealName, quickPick: quickPick, locked: false, attendance: [:])
    }

    @Test func onlyNightsFromTonightOnAndNotAlreadyThisMeal() {
        let nights = [night(0), night(1), night(2, mealID: tacos, mealName: "Tacos"), night(3), night(4)]
        let layout = WeekLayout(nights: nights, today: sunday.adding(days: 1))
        #expect(PlanIt.choices(in: layout, for: tacos).map(\.date) == [1, 3, 4].map { sunday.adding(days: $0) })
    }

    @Test func eachNightSaysWhatItHoldsNow() {
        #expect(PlanIt.currentPick(night(0, mealID: UUID(), mealName: "Chili")) == "Chili")
        #expect(PlanIt.currentPick(night(0, quickPick: .leftovers)) == DayCardText.quickPickLabel(.leftovers))
        #expect(PlanIt.currentPick(night(0)) == "Open")
    }
}

struct PlanItStateTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)
    private let tacos = UUID()

    private func layout(_ offsets: [Int], tacosOn: Set<Int> = [], today: Int = 0) -> WeekLayout {
        let nights = offsets.map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil,
                      mealID: tacosOn.contains(offset) ? tacos : nil, mealName: nil, quickPick: nil, locked: false,
                      attendance: [:])
        }
        return WeekLayout(nights: nights, today: sunday.adding(days: today))
    }

    @Test func beforeTheFirstLoadItWaitsAndAFailedLoadSaysSo() {
        #expect(PlanIt.state(layout: nil, mealID: tacos, isLoading: false, hasLoaded: false, loadError: nil) == .loading)
        #expect(PlanIt.state(layout: nil, mealID: tacos, isLoading: true, hasLoaded: false, loadError: "x") == .loading)
        #expect(PlanIt.state(layout: nil, mealID: tacos, isLoading: false, hasLoaded: false, loadError: "Offline")
            == .failed("Offline"))
    }

    @Test func aLoadedWeekThatIsntStartedPointsToThisWeek() {
        #expect(PlanIt.state(layout: nil, mealID: tacos, isLoading: false, hasLoaded: true, loadError: nil) == .noWeek)
    }

    @Test func nothingLeftWhenEveryNightAheadAlreadyHasIt() {
        let state = PlanIt.state(layout: layout([0, 1, 2], tacosOn: [2], today: 2), mealID: tacos, isLoading: false,
                                 hasLoaded: true, loadError: nil)
        #expect(state == .noNightsLeft)
    }

    @Test func otherwiseTheNightsAhead() {
        let state = PlanIt.state(layout: layout([0, 1, 2]), mealID: tacos, isLoading: false, hasLoaded: true,
                                 loadError: "an old error from another screen")
        guard case .nights(let nights) = state else { Issue.record("expected nights"); return }
        #expect(nights.count == 3)
    }
}
