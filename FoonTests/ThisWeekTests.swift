import Foundation
import Synchronization
import Testing
@testable import Foon

struct WeekLayoutTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func nights(planned: Set<Int> = []) -> [WeekNight] {
        (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil,
                      mealID: planned.contains(offset) ? UUID() : nil,
                      mealName: planned.contains(offset) ? "Meal \(offset)" : nil,
                      quickPick: nil, locked: false, attendance: [:])
        }
    }

    @Test func tonightIsOnTopThenTheRestOfTheWeekWithPastNightsSetAside() {
        let layout = WeekLayout(nights: nights(), today: sunday.adding(days: 3))
        #expect(layout.tonight?.date == sunday.adding(days: 3))
        #expect(layout.upcoming.map(\.date) == (4..<7).map { sunday.adding(days: $0) })
        #expect(layout.past.map(\.date) == (0..<3).map { sunday.adding(days: $0) })
    }

    @Test func aWeekThatHasNotStartedHasNoTonight() {
        let layout = WeekLayout(nights: nights(), today: sunday.adding(days: -2))
        #expect(layout.tonight == nil)
        #expect(layout.upcoming.count == 7)
        #expect(layout.past.isEmpty)
    }

    @Test(arguments: [
        (Set<Int>(), WeekLayout.Progress.unplanned),
        (Set([3, 4]), .partlyPlanned),
        (Set([3, 4, 5, 6]), .planned)
    ])
    func progressCountsOnlyTonightAndLater(planned: Set<Int>, progress: WeekLayout.Progress) {
        // Past nights left empty don't make a week "partly planned".
        #expect(WeekLayout(nights: nights(planned: planned), today: sunday.adding(days: 3)).progress == progress)
    }

    @Test func emptyNightsAreTheOnesStillToFill() {
        let layout = WeekLayout(nights: nights(planned: [3, 5]), today: sunday.adding(days: 3))
        #expect(layout.emptyNights.map(\.date) == [sunday.adding(days: 4), sunday.adding(days: 6)])
    }

    @Test func aQuickPickCountsAsPlanned() {
        var week = nights()
        week[3].quickPick = .takeout
        #expect(WeekLayout(nights: week, today: sunday.adding(days: 3)).emptyNights.map(\.date)
            == (4..<7).map { sunday.adding(days: $0) })
    }
}

struct NightBadgeTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)

    @Test func allergyFlagsOnlyNameWhoIsHome() {
        let mac = LibraryMeal.fixture(name: "Mac and cheese", ingredients: ["milk", "elbow macaroni"])
        let allergies = [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.milk]),
                         MemberAllergies(memberID: owen.id, firstName: "Owen", allergens: [.milk])]
        let badges = NightBadges.badges(meal: mac, library: [mac], allergies: allergies, home: [nora.id])
        #expect(badges == [.allergy("Contains milk (Nora)")])
        #expect(NightBadges.badges(meal: mac, library: [mac], allergies: allergies, home: []).isEmpty)
    }

    @Test func prepStepsBecomeAPrepBadge() {
        let chicken = LibraryMeal.fixture(name: "Grilled chicken",
                                          prepSteps: [PrepStep(step: "Move the chicken to the fridge to thaw", leadHours: 24)])
        #expect(NightBadges.badges(meal: chicken, library: [chicken], allergies: [], home: [])
            == [.prep("Move the chicken to the fridge to thaw · 1 day ahead")])
    }
}

@MainActor
struct WeekStoreLockTests {
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func week() -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map {
            WeekNight(id: UUID(), date: sunday.adding(days: $0), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [:])
        })
    }

    @Test func lockingANightShowsAtOnceAndIsSent() async {
        let sent = Mutex<[Bool]>([])
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setLocked: { _, locked in sent.withLock { $0.append(locked) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.toggleLock(nightID: existing.nights[2].id)
        #expect(store.week?.nights[2].locked == true)
        #expect(sent.withLock { $0 } == [true])
    }

    @Test func setEffortGoesStraightToTheChosenEffort() async {
        let sent = Mutex<[NightEffort]>([])
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(
            week: { _, _ in existing },
            setEffort: { _, effort in sent.withLock { $0.append(effort) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.setEffort(.event, nightID: existing.nights[2].id)
        #expect(store.week?.nights[2].effort == .event)
        #expect(sent.withLock { $0 } == [.event])
        await store.setEffort(.event, nightID: existing.nights[2].id)
        #expect(sent.withLock { $0 } == [.event], "no change, nothing sent")
    }

    @Test func layoutFollowsTheStoresToday() async {
        let existing = week()
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in existing }),
                              today: { CalendarDay(year: 2026, month: 11, day: 4) })
        await store.load(settings: HouseholdSettings())
        #expect(store.layout?.tonight?.date == CalendarDay(year: 2026, month: 11, day: 4))
    }
}
