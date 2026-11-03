import Foundation
import Testing
@testable import Foon

/// Calendar awareness (#64): events near dinner suggest marking a night rushed. Never a change on its own.
struct CalendarBusyTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)
    private let ana = UUID()
    private let ben = UUID()

    private var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = "America/Chicago"
        settings.dinnerTime = "18:00"
        return settings
    }

    private var calendar: Calendar { DinnerPrompts.calendar(for: settings) }

    /// A moment on the household's clock, `days` after today.
    private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let time = String(format: "%02d:%02d", hour, minute)
        return DinnerPrompts.moment(time, on: today.adding(days: days), calendar: calendar)!
    }

    private func night(days: Int = 0, effort: NightEffort = .normal, dinnerTime: String? = nil,
                       attendance: [UUID: Bool]? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: today.adding(days: days), effort: effort, dinnerTime: dinnerTime, mealID: nil,
                  mealName: nil, quickPick: nil, locked: false, attendance: attendance ?? [ana: true, ben: true])
    }

    private func event(_ start: Date, _ end: Date, allDay: Bool = false, free: Bool = false,
                       declined: Bool = false) -> BusyEvent {
        BusyEvent(start: start, end: end, isAllDay: allDay, isFree: free, isDeclined: declined)
    }

    private func suggested(_ events: [BusyEvent], _ nights: [WeekNight], settings: HouseholdSettings? = nil,
                           now: Date? = nil, dismissed: Set<UUID> = []) -> Set<UUID> {
        CalendarBusy.suggestions(events: events, nights: nights, settings: settings ?? self.settings,
                                 now: now ?? at(9), dismissed: dismissed)
    }

    // MARK: - The window

    @Test func theWindowRunsFromNinetyMinutesBeforeDinnerToAnHourAfter() throws {
        let window = try #require(CalendarBusy.window(for: night(), settings: settings))
        #expect(window.start == at(16, 30))
        #expect(window.end == at(19))
    }

    @Test func aNightsOwnDinnerTimeMovesTheWindow() throws {
        let window = try #require(CalendarBusy.window(for: night(dinnerTime: "19:30:00"), settings: settings))
        #expect(window.start == at(18))
        #expect(window.end == at(20, 30))
    }

    @Test func theWindowIsOnTheHouseholdsClockNotThePhones() throws {
        var eastern = settings
        eastern.timeZone = "America/New_York"
        let chicago = try #require(CalendarBusy.window(for: night(), settings: settings))
        let newYork = try #require(CalendarBusy.window(for: night(), settings: eastern))
        #expect(chicago.start.timeIntervalSince(newYork.start) == 3600)
    }

    // MARK: - Which events count

    @Test func withNoSavedTimeZoneTheWindowIsOnThisDevicesClockLikeTheDays() throws {
        // An older household with no time zone saved reads its days on the phone's clock, so dinner does too.
        var unzoned = HouseholdSettings()
        unzoned.dinnerTime = "18:00"
        let window = try #require(CalendarBusy.window(for: night(), settings: unzoned))
        let dinner = try #require(DinnerPrompts.moment("18:00", on: today, calendar: .current))
        #expect(window.start == dinner.addingTimeInterval(-90 * 60))
    }

    @Test func anEventInsideTheWindowSuggestsRushed() {
        let tonight = night()
        #expect(suggested([event(at(17), at(18))], [tonight]) == [tonight.id])
    }

    @Test func anEventOverlappingEitherEdgeCounts() {
        let tonight = night()
        let tomorrow = night(days: 1)
        let events = [event(at(15), at(16, 45)), event(at(18, 45, days: 1), at(21, days: 1))]
        #expect(suggested(events, [tonight, tomorrow]) == [tonight.id, tomorrow.id])
    }

    @Test func anEventThatEndsAsTheWindowOpensDoesNot() {
        let events = [event(at(15), at(16, 30)), event(at(19), at(20))]
        #expect(suggested(events, [night()]).isEmpty)
    }

    @Test func allDayFreeAndDeclinedEventsDont() {
        let events = [event(at(0), at(0, days: 1), allDay: true), event(at(17), at(18), free: true),
                      event(at(17), at(18), declined: true)]
        #expect(suggested(events, [night()]).isEmpty)
    }

    @Test func noEventsNoSuggestions() {
        #expect(suggested([], [night(), night(days: 1)]).isEmpty)
    }

    // MARK: - Which nights get one

    @Test func onlyNormalNightsGetOne() {
        let nights = [night(effort: .rushed), night(effort: .full), night(effort: .event)]
        #expect(suggested([event(at(17), at(18))], nights).isEmpty)
    }

    @Test func notAnAwayNight() {
        var away = settings
        away.awayDates = [AwayDates(from: today, to: today.adding(days: 2))]
        #expect(suggested([event(at(17), at(18))], [night()], settings: away).isEmpty)
    }

    @Test func notANightNobodysHomeFor() {
        let empty = night(attendance: [ana: false, ben: false])
        #expect(suggested([event(at(17), at(18))], [empty]).isEmpty)
    }

    @Test func notANightThatsGoneBy() {
        let yesterday = night(days: -1)
        let tonight = night()
        let events = [event(at(17, days: -1), at(18, days: -1)), event(at(17), at(18))]
        #expect(suggested(events, [yesterday, tonight], now: at(20)).isEmpty)
        #expect(suggested(events, [yesterday, tonight], now: at(18, 30)) == [tonight.id])
    }

    @Test func aDismissedNightStaysQuiet() {
        let tonight = night()
        let tomorrow = night(days: 1)
        let events = [event(at(17), at(18)), event(at(17, days: 1), at(18, days: 1))]
        #expect(suggested(events, [tonight, tomorrow], dismissed: [tonight.id]) == [tomorrow.id])
    }

    // MARK: - What to read

    @Test func readsFromTheFirstOpenWindowToTheLast() throws {
        let nights = [night(days: -1), night(), night(days: 3, effort: .rushed), night(days: 2)]
        let range = try #require(CalendarBusy.readRange(nights: nights, settings: settings, now: at(9)))
        #expect(range.start == at(16, 30))
        #expect(range.end == at(19, days: 2))
    }

    @Test func readsNothingWhenNoNightCouldTakeOne() {
        let nights = [night(effort: .rushed), night(days: 1, effort: .event)]
        #expect(CalendarBusy.readRange(nights: nights, settings: settings, now: at(9)) == nil)
    }
}
