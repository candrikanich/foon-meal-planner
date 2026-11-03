import Foundation
import Testing
@testable import Foon

/// The device's switch for calendar awareness (#64), and reading events only while it's on.
@MainActor
struct CalendarBusyStoreTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)

    private var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = "America/Chicago"
        return settings
    }

    private func at(_ hour: Int, days: Int = 0) -> Date {
        DinnerPrompts.moment(String(format: "%02d:00", hour), on: today.adding(days: days),
                             calendar: DinnerPrompts.calendar(for: settings))!
    }

    private func night(days: Int = 0) -> WeekNight {
        WeekNight(id: UUID(), date: today.adding(days: days), effort: .normal, dinnerTime: nil, mealID: nil,
                  mealName: nil, quickPick: nil, locked: false, attendance: [UUID(): true])
    }

    private func defaults() -> UserDefaults {
        let name = "CalendarBusyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A source that grants or refuses, counts its reads, and hands back one event at five tonight.
    private final class Stub: @unchecked Sendable {
        var access: CalendarAccess
        let grants: Bool
        var reads: [DateInterval] = []
        var events: [BusyEvent] = []

        init(access: CalendarAccess = .notAsked, grants: Bool = true) {
            self.access = access
            self.grants = grants
        }

        var source: CalendarSource {
            CalendarSource(
                access: { self.access },
                requestAccess: {
                    self.access = self.grants ? .granted : .refused
                    return self.access
                },
                events: { range in
                    self.reads.append(range)
                    return self.events
                }
            )
        }
    }

    private func store(_ stub: Stub, defaults: UserDefaults? = nil) -> CalendarBusyStore {
        let morning = at(9)
        return CalendarBusyStore(source: stub.source, defaults: defaults ?? self.defaults(), now: { morning })
    }

    @Test func offByDefaultAndReadsNothing() async {
        let stub = Stub(access: .granted)
        let store = store(stub)
        #expect(!store.isOn)
        await store.refresh(nights: [night()], settings: settings)
        #expect(stub.reads.isEmpty)
    }

    @Test func turningOnAsksAndThenReads() async {
        let stub = Stub()
        stub.events = [BusyEvent(start: at(17), end: at(18), isAllDay: false, isFree: false)]
        let store = store(stub)
        let tonight = night()
        await store.turnOn()
        #expect(store.isOn)
        #expect(store.access == .granted)
        await store.refresh(nights: [tonight], settings: settings)
        #expect(stub.reads.count == 1)
        #expect(store.suggestions(nights: [tonight], settings: settings) == [tonight.id])
    }

    @Test func refusedStaysOffAndSaysSo() async {
        let stub = Stub(grants: false)
        let store = store(stub)
        await store.turnOn()
        #expect(!store.isOn)
        #expect(store.access == .refused)
    }

    @Test func turningOffForgetsEverythingAtOnce() async {
        let stub = Stub(access: .granted)
        stub.events = [BusyEvent(start: at(17), end: at(18), isAllDay: false, isFree: false)]
        let store = store(stub)
        let tonight = night()
        await store.turnOn()
        await store.refresh(nights: [tonight], settings: settings)
        store.turnOff()
        #expect(store.suggestions(nights: [tonight], settings: settings).isEmpty)
        await store.refresh(nights: [tonight], settings: settings)
        #expect(stub.reads.count == 1)
    }

    @Test func accessTakenAwayInSettingsStopsReading() async {
        let stub = Stub(access: .granted)
        stub.events = [BusyEvent(start: at(17), end: at(18), isAllDay: false, isFree: false)]
        let store = store(stub)
        let tonight = night()
        await store.turnOn()
        await store.refresh(nights: [tonight], settings: settings)
        stub.access = .refused
        await store.refresh(nights: [tonight], settings: settings)
        #expect(stub.reads.count == 1)
        #expect(store.access == .refused)
        #expect(store.suggestions(nights: [tonight], settings: settings).isEmpty)
    }

    @Test func theSwitchAndDismissalsAreKeptOnThisDevice() async {
        let stub = Stub(access: .granted)
        stub.events = [BusyEvent(start: at(17), end: at(18), isAllDay: false, isFree: false)]
        let kept = defaults()
        let tonight = night()
        let first = store(stub, defaults: kept)
        await first.turnOn()
        first.dismiss(tonight.id)

        let again = store(stub, defaults: kept)
        #expect(again.isOn)
        await again.refresh(nights: [tonight], settings: settings)
        #expect(again.suggestions(nights: [tonight], settings: settings).isEmpty)
    }

    @Test func nothingToReadWhenNoNightCouldTakeASuggestion() async {
        let stub = Stub(access: .granted)
        let store = store(stub)
        await store.turnOn()
        var rushed = night()
        rushed.effort = .rushed
        await store.refresh(nights: [rushed], settings: settings)
        #expect(stub.reads.isEmpty)
    }
}
