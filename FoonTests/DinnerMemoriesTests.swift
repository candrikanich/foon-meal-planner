import Foundation
import Testing
@testable import Foon

/// Dinner memories (#65, part 3): photos from this device's library taken around dinner on logged nights. Only the
/// pure half is here; the PhotoKit reader is stubbed.
struct DinnerMemoriesTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)

    private var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = "America/New_York"
        settings.dinnerTime = "18:00"
        return settings
    }

    private var calendar: Calendar { DinnerPrompts.calendar(for: settings) }

    private func at(_ hour: Int, _ minute: Int = 0, on day: CalendarDay, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour,
                                                  minute: minute))!
    }

    private func log(_ day: CalendarDay, dinnerTime: String? = nil, meal: String? = "Tacos",
                     quickPick: QuickPick? = nil, approved: Bool = true) -> MemoryLog {
        MemoryLog(nightID: UUID(), date: day, dinnerTime: dinnerTime, mealName: quickPick == nil ? meal : nil,
                  quickPick: quickPick, hasMeal: quickPick == nil && meal != nil, approved: approved)
    }

    private func night(_ day: CalendarDay, dinnerTime: String? = nil, meal: String = "Tacos") -> MemoryNight {
        MemoryNight(id: UUID(), date: day, dinnerTime: dinnerTime, title: meal)
    }

    private func photo(_ id: String, _ date: Date) -> PhotoStamp {
        PhotoStamp(id: id, createdAt: date)
    }

    // MARK: - Which nights

    @Test func onlyApprovedNightsEatenAtHomeCount() {
        let logs = [
            log(today, meal: "Tacos"),
            log(today.adding(days: -1), quickPick: .leftovers),
            log(today.adding(days: -2), quickPick: .takeout),
            log(today.adding(days: -3), quickPick: .freezerRaid),
            log(today.adding(days: -4), quickPick: .eatOut),
            log(today.adding(days: -5), quickPick: .fendForYourselves),
            log(today.adding(days: -6), meal: "Chili", approved: false),
            log(today.adding(days: -7), meal: nil)
        ]
        let nights = DinnerMemories.nights(from: logs)
        #expect(nights.map(\.date) == [0, -1, -2, -3].map { today.adding(days: $0) })
    }

    @Test func aNightIsTitledByItsDishOrItsQuickPick() {
        let nights = DinnerMemories.nights(from: [log(today, meal: "Tacos"),
                                                  log(today.adding(days: -1), quickPick: .leftovers)])
        #expect(nights.map(\.title) == ["Tacos", "Leftovers"])
    }

    @Test func aDishWhoseNameIsntReadableStillCountsWithAPlainTitle() {
        let unnamed = MemoryLog(nightID: UUID(), date: today, dinnerTime: nil, mealName: nil, quickPick: nil,
                                hasMeal: true, approved: true)
        #expect(DinnerMemories.nights(from: [unnamed]).map(\.title) == ["Dinner"])
    }

    @Test func aLogDecodesFromTheServersRow() throws {
        let json = """
            [{"meal_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "quick_pick": null, "meals": {"name": "Tacos"},
              "plan_nights": {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "date": "2026-10-30",
                              "dinner_time": "18:30:00", "plans": {"approved_at": "2026-10-25T20:00:00+00:00"}}},
             {"meal_id": null, "quick_pick": "takeout", "meals": null,
              "plan_nights": {"id": "8F9619FF-8B86-D011-B42D-00C04FC964FF", "date": "2026-10-31",
                              "dinner_time": null, "plans": {"approved_at": null}}}]
            """
        let logs = try JSONDecoder().decode([MemoryLog].self, from: Data(json.utf8))
        #expect(logs[0].date == CalendarDay(year: 2026, month: 10, day: 30))
        #expect(logs[0].dinnerTime == "18:30:00")
        #expect(logs[0].mealName == "Tacos")
        #expect(logs[0].hasMeal)
        #expect(logs[0].approved)
        #expect(logs[1].quickPick == .takeout)
        #expect(!logs[1].approved)
    }

    // MARK: - The window

    @Test func theWindowRunsFromHalfAnHourBeforeDinnerToTwoHoursAfter() throws {
        let window = try #require(DinnerMemories.window(for: night(today), settings: settings))
        #expect(window.start == at(17, 30, on: today))
        #expect(window.end == at(20, on: today))
    }

    @Test func aNightsOwnDinnerTimeMovesTheWindow() throws {
        let window = try #require(DinnerMemories.window(for: night(today, dinnerTime: "19:15:00"), settings: settings))
        #expect(window.start == at(18, 45, on: today))
        #expect(window.end == at(21, 15, on: today))
    }

    @Test func theWindowIsOnTheHouseholdsClock() throws {
        var pacific = settings
        pacific.timeZone = "America/Los_Angeles"
        let eastern = try #require(DinnerMemories.window(for: night(today), settings: settings))
        let west = try #require(DinnerMemories.window(for: night(today), settings: pacific))
        #expect(west.start.timeIntervalSince(eastern.start) == 3 * 3600)
    }

    @Test func onTheDayTheClocksGoBackDinnerIsStillAtSix() throws {
        let fallBack = CalendarDay(year: 2026, month: 11, day: 1)
        let window = try #require(DinnerMemories.window(for: night(fallBack), settings: settings))
        #expect(window.start == at(17, 30, on: fallBack))
        #expect(window.duration == 2.5 * 3600)
    }

    @Test func onTheDayTheClocksGoForwardDinnerIsStillAtSix() throws {
        let springForward = CalendarDay(year: 2026, month: 3, day: 8)
        let window = try #require(DinnerMemories.window(for: night(springForward), settings: settings))
        #expect(window.start == at(17, 30, on: springForward))
        #expect(window.duration == 2.5 * 3600)
    }

    @Test func aDinnerNearMidnightRunsIntoTheNextDay() throws {
        let window = try #require(DinnerMemories.window(for: night(today, dinnerTime: "23:30"), settings: settings))
        #expect(window.start == at(23, on: today))
        #expect(window.end == at(1, 30, on: today.adding(days: 1)))
    }

    @Test func aDinnerTimeThatCantBeReadHasNoWindow() {
        #expect(DinnerMemories.window(for: night(today, dinnerTime: "soon"), settings: settings) == nil)
    }

    @Test func theWindowsAreReadOnePerNight() {
        let nights = [night(today), night(today.adding(days: -1)), night(today, dinnerTime: "nope")]
        #expect(DinnerMemories.windows(for: nights, settings: settings).count == 2)
    }

    // MARK: - Which photos go where

    @Test func photosInsideTheWindowBelongToThatNight() throws {
        let tacos = night(today)
        let dinners = DinnerMemories.dinners(nights: [tacos], photos: [
            photo("before", at(17, 29, on: today)),
            photo("start", at(17, 30, on: today)),
            photo("during", at(18, 10, on: today)),
            photo("end", at(20, on: today)),
            photo("after", at(20, 1, on: today))
        ], settings: settings)
        let only = try #require(dinners.first)
        #expect(dinners.count == 1)
        #expect(only.night == tacos)
        #expect(only.photoIDs == ["start", "during", "end"])
    }

    @Test func nightsWithoutPhotosArentShown() {
        let dinners = DinnerMemories.dinners(nights: [night(today), night(today.adding(days: -1))],
                                             photos: [photo("a", at(18, on: today))], settings: settings)
        #expect(dinners.map(\.night.date) == [today])
    }

    @Test func newestNightComesFirstAndPhotosRunInTheOrderTheyWereTaken() {
        let yesterday = today.adding(days: -1)
        let dinners = DinnerMemories.dinners(nights: [night(yesterday), night(today)], photos: [
            photo("late", at(19, on: today)),
            photo("early", at(18, on: today)),
            photo("old", at(18, on: yesterday))
        ], settings: settings)
        #expect(dinners.map(\.night.date) == [today, yesterday])
        #expect(dinners.first?.photoIDs == ["early", "late"])
    }

    @Test func aPhotoInTwoWindowsGoesToTheNearerDinner() {
        // A late dinner, then an early one just after midnight on the next date: the windows overlap.
        let late = night(today, dinnerTime: "23:00")
        let early = night(today.adding(days: 1), dinnerTime: "00:30")
        let dinners = DinnerMemories.dinners(nights: [late, early], photos: [
            photo("nearLate", at(23, 20, on: today)),
            photo("nearEarly", at(0, 20, on: today.adding(days: 1)))
        ], settings: settings)
        #expect(dinners.first { $0.night == late }?.photoIDs == ["nearLate"])
        #expect(dinners.first { $0.night == early }?.photoIDs == ["nearEarly"])
    }

    @Test func aPhotoExactlyBetweenTwoDinnersGoesToTheOneAlreadyStarted() {
        let late = night(today, dinnerTime: "23:00")
        let early = night(today.adding(days: 1), dinnerTime: "01:00")
        let middle = photo("middle", at(0, on: today.adding(days: 1)))
        let dinners = DinnerMemories.dinners(nights: [late, early], photos: [middle], settings: settings)
        #expect(dinners.map(\.night) == [late])
    }

    @Test func theSamePhotoReadTwiceShowsOnce() {
        let dinners = DinnerMemories.dinners(nights: [night(today)], photos: [
            photo("a", at(18, on: today)), photo("a", at(18, on: today))
        ], settings: settings)
        #expect(dinners.first?.photoIDs == ["a"])
    }

    // MARK: - The row of thumbnails

    @Test func aRowShowsUpToSixAndCountsTheRest() {
        let ids = (1...9).map { "p\($0)" }
        let dinner = MemoryDinner(night: night(today), photoIDs: ids)
        #expect(dinner.shownPhotoIDs == Array(ids.prefix(6)))
        #expect(dinner.morePhotos == 3)
        let small = MemoryDinner(night: night(today), photoIDs: Array(ids.prefix(6)))
        #expect(small.shownPhotoIDs.count == 6)
        #expect(small.morePhotos == 0)
    }

    @Test func aThumbnailIsLabelledWithTheNightNotAnyone() {
        let night = night(CalendarDay(year: 2026, month: 10, day: 30))
        let label = DinnerMemories.photoLabel(for: night, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(label == "Photo from dinner, Friday, October 30")
    }

    // MARK: - Paging

    @Test func theFirstPageIsThisMonthAndTheTwoBeforeThroughToday() {
        let page = DinnerMemories.page(0, today: today, calendar: calendar)
        #expect(page.from == CalendarDay(year: 2026, month: 9, day: 1))
        #expect(page.through == today)
    }

    @Test func eachPageReachesThreeMonthsFurtherBack() {
        let page = DinnerMemories.page(1, today: today, calendar: calendar)
        #expect(page.from == CalendarDay(year: 2026, month: 6, day: 1))
        #expect(page.through == CalendarDay(year: 2026, month: 8, day: 31))
    }

    @Test func pagesCrossTheYear() {
        let january = CalendarDay(year: 2027, month: 1, day: 15)
        #expect(DinnerMemories.page(0, today: january, calendar: calendar).from
                == CalendarDay(year: 2026, month: 11, day: 1))
        let second = DinnerMemories.page(1, today: january, calendar: calendar)
        #expect(second.from == CalendarDay(year: 2026, month: 8, day: 1))
        #expect(second.through == CalendarDay(year: 2026, month: 10, day: 31))
    }
}

/// The screen's store: the switch, access, and paging, with the library and the server stubbed.
@MainActor
struct DinnerMemoriesStoreTests {
    private let today = CalendarDay(year: 2026, month: 11, day: 3)

    private var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = "America/New_York"
        return settings
    }

    private func defaults() -> UserDefaults {
        let name = "DinnerMemoriesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private nonisolated static func log(_ day: CalendarDay) -> MemoryLog {
        MemoryLog(nightID: UUID(), date: day, dinnerTime: nil, mealName: "Tacos", quickPick: nil, hasMeal: true,
                  approved: true)
    }

    private func library(access: PhotoAccess = .full, onRequest: PhotoAccess = .full,
                         photos: @escaping @Sendable ([DateInterval]) -> [PhotoStamp] = { _ in [] })
        -> PhotoLibrarySource {
        PhotoLibrarySource(access: { access }, requestAccess: { onRequest }, photos: { photos($0) },
                           image: { _, _ in nil })
    }

    @Test func itsOffUntilSomeoneTurnsItOn() {
        let store = DinnerMemoriesStore(source: library(), defaults: defaults())
        #expect(!store.isOn)
        #expect(!store.isShowing)
    }

    @Test func turningItOnAsksForAccessAndRemembersTheSwitchOnly() async {
        let defaults = defaults()
        let store = DinnerMemoriesStore(source: library(access: .notAsked, onRequest: .limited), defaults: defaults)
        await store.turnOn()
        #expect(store.isOn)
        #expect(store.access == .limited)
        #expect(store.isShowing)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("dinnerMemories") }
                == [DinnerMemoriesStore.onKey])
    }

    @Test func refusingAccessLeavesItOff() async {
        let store = DinnerMemoriesStore(source: library(access: .notAsked, onRequest: .refused), defaults: defaults())
        await store.turnOn()
        #expect(!store.isOn)
        #expect(store.access == .refused)
    }

    @Test func aPageReadsOnlyItsNightsWindows() async {
        let windowsRead = Locked<[DateInterval]>([])
        let night = today.adding(days: -3)
        let store = DinnerMemoriesStore(source: library(photos: { windows in
            windowsRead.value += windows
            return [PhotoStamp(id: "a", createdAt: windows[0].start.addingTimeInterval(600))]
        }), defaults: defaults())
        await store.turnOn()
        await store.loadMore(logs: { _, _ in [Self.log(night)] }, settings: settings, today: today)
        #expect(windowsRead.value.count == 1)
        #expect(store.dinners.map(\.night.date) == [night])
        #expect(store.dinners.first?.photoIDs == ["a"])
    }

    @Test func pagingGoesBackUntilAPageHasNoLogs() async {
        let asked = Locked<[CalendarDay]>([])
        let store = DinnerMemoriesStore(source: library(), defaults: defaults())
        await store.turnOn()
        let logs: @Sendable (CalendarDay, CalendarDay) async throws -> [MemoryLog] = { from, _ in
            asked.value.append(from)
            return asked.value.count == 1 ? [MemoryLog(nightID: UUID(), date: from, dinnerTime: nil, mealName: "Soup",
                                                       quickPick: nil, hasMeal: true, approved: true)] : []
        }
        await store.loadMore(logs: logs, settings: settings, today: today)
        #expect(!store.reachedEnd)
        await store.loadMore(logs: logs, settings: settings, today: today)
        #expect(store.reachedEnd)
        await store.loadMore(logs: logs, settings: settings, today: today)
        #expect(asked.value.count == 2)
        #expect(store.isEmpty)
    }

    @Test func turningItOffDropsEverythingAndStopsReading() async {
        let defaults = defaults()
        let store = DinnerMemoriesStore(source: library(photos: { windows in
            [PhotoStamp(id: "a", createdAt: windows[0].start)]
        }), defaults: defaults)
        await store.turnOn()
        await store.loadMore(logs: { [today] _, _ in [Self.log(today)] }, settings: settings, today: today)
        #expect(!store.dinners.isEmpty)
        store.turnOff()
        #expect(store.dinners.isEmpty)
        #expect(!defaults.bool(forKey: DinnerMemoriesStore.onKey))
        await store.loadMore(logs: { [today] _, _ in [Self.log(today)] }, settings: settings, today: today)
        #expect(store.dinners.isEmpty)
    }

    @Test func accessTakenAwayInSettingsStopsReading() async {
        let defaults = defaults()
        defaults.set(true, forKey: DinnerMemoriesStore.onKey)
        let read = Locked(false)
        let store = DinnerMemoriesStore(source: library(access: .refused, photos: { _ in
            read.value = true
            return []
        }), defaults: defaults)
        #expect(store.isOn)
        await store.loadMore(logs: { [today] _, _ in [Self.log(today)] }, settings: settings, today: today)
        #expect(store.dinners.isEmpty)
        #expect(!store.isShowing)
        #expect(!read.value)
    }

    @Test func aFailedPageSaysSoAndCanBeTriedAgain() async {
        let store = DinnerMemoriesStore(source: library(), defaults: defaults())
        await store.turnOn()
        await store.loadMore(logs: { _, _ in throw URLError(.notConnectedToInternet) }, settings: settings,
                             today: today)
        #expect(store.failed)
        #expect(!store.reachedEnd)
        await store.loadMore(logs: { _, _ in [] }, settings: settings, today: today)
        #expect(!store.failed)
        #expect(store.reachedEnd)
    }

    @Test func aCancelledReadIsntAFailure() async {
        let store = DinnerMemoriesStore(source: library(), defaults: defaults())
        await store.turnOn()
        await store.loadMore(logs: { _, _ in throw CancellationError() }, settings: settings, today: today)
        #expect(!store.failed)
        #expect(store.pagesLoaded == 0)
    }

    @Test func aChangeOfAccessStartsOverAndAsksTheScreenToReadAgain() async {
        let access = Locked(PhotoAccess.limited)
        let source = PhotoLibrarySource(access: { access.value }, requestAccess: { access.value },
                                        photos: { _ in [] }, image: { _, _ in nil })
        let store = DinnerMemoriesStore(source: source, defaults: defaults())
        await store.turnOn()
        await store.loadMore(logs: { [today] _, _ in [Self.log(today)] }, settings: settings, today: today)
        let before = store.nextRead
        access.value = .full
        store.checkAccess()
        #expect(store.pagesLoaded == 0)
        #expect(store.nextRead != before)
        #expect(store.isShowing)
    }

    @Test func signingOutClearsTheSwitch() {
        let defaults = defaults()
        defaults.set(true, forKey: DinnerMemoriesStore.onKey)
        DinnerMemoriesStore.clearDevice(defaults: defaults)
        #expect(defaults.object(forKey: DinnerMemoriesStore.onKey) == nil)
    }
}

/// A box the stubbed closures can write to across their `@Sendable` boundary.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
