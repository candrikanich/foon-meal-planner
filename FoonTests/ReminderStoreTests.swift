import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Foon

/// What the store hands the notification center. Not the center itself: that's Apple's to test.
private final class SpyCenter: Sendable {
    struct State {
        var permission = ReminderPermission.on
        var pending: [String] = []
        var added: [PlannedReminder] = []
        var intervals: [String: TimeInterval] = [:]
        var removed: [String] = []
        var requests = 0
        var clears = 0
        var addFails = false
    }

    let state = Mutex(State())
    /// Runs inside `add`, once per call, for tests that need something to happen mid-run.
    let onAdd = Mutex<(@Sendable () async -> Void)?>(nil)

    var center: ReminderCenter {
        ReminderCenter(
            permission: { self.state.withLock { $0.permission } },
            requestPermission: {
                self.state.withLock {
                    $0.requests += 1
                    return $0.permission
                }
            },
            pendingIDs: { self.state.withLock { $0.pending } },
            add: { reminder, after in
                let hook = self.onAdd.withLock { hook in
                    defer { hook = nil }
                    return hook
                }
                await hook?()
                return self.state.withLock {
                    guard !$0.addFails else { return false }
                    $0.added.append(reminder)
                    $0.intervals[reminder.id] = after
                    if !$0.pending.contains(reminder.id) { $0.pending.append(reminder.id) }
                    return true
                }
            },
            remove: { ids in
                self.state.withLock { state in
                    state.removed += ids
                    state.pending.removeAll(where: ids.contains)
                }
            },
            removeEverything: {
                self.state.withLock {
                    $0.clears += 1
                    $0.pending = []
                }
            }
        )
    }

    var pending: [String] { state.withLock { $0.pending } }
    var added: [PlannedReminder] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }

    func set(permission: ReminderPermission) { state.withLock { $0.permission = permission } }
}

private final class SpyServer: Sendable {
    struct State {
        var weeks: [ReminderWeek] = []
        var offline = false
        var uploadsFail = false
        var uploads: [[NotificationLogEntry]] = []
    }

    let state = Mutex(State())

    var client: NotificationClient {
        NotificationClient(
            weeks: { _, _, _ in
                try self.state.withLock {
                    if $0.offline { throw URLError(.notConnectedToInternet) }
                    return $0.weeks
                }
            },
            record: { _, entries in
                try self.state.withLock {
                    if $0.uploadsFail { throw URLError(.notConnectedToInternet) }
                    $0.uploads.append(entries)
                }
            }
        )
    }

    var uploads: [[NotificationLogEntry]] { state.withLock { $0.uploads } }
    func set(weeks: [ReminderWeek]) { state.withLock { $0.weeks = weeks } }
    func set(offline: Bool) { state.withLock { $0.offline = offline } }
    func set(uploadsFail: Bool) { state.withLock { $0.uploadsFail = uploadsFail } }
}

@MainActor
private final class Harness {
    static let timeZone = "America/New_York"
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static func day(_ day: Int) -> CalendarDay { CalendarDay(year: 2026, month: 11, day: day) }

    let ann = Member.fixture(firstName: "Ann", role: .planner, userID: UUID())
    let kim = Member.fixture(firstName: "Kim", ageGroup: .kid, userID: UUID())
    let household = Household.sample.id
    let center = SpyCenter()
    let server = SpyServer()
    let session = ReminderSession()
    let device: ReminderDevice
    let container: ModelContainer
    var currentTime = Harness.at(8, 10)
    let chili = UUID()
    lazy var night = ReminderNight(id: UUID(), date: Self.day(10), mealID: chili,
                                   prepSteps: [PrepStep(step: "Thaw the beef", leadHours: 24)],
                                   attendance: [ann.id: true, kim.id: true])

    init() throws {
        device = ReminderDevice(defaults: UserDefaults(suiteName: "foon.tests.\(UUID().uuidString)")!)
        container = try SyncService.inMemoryContainer()
    }

    var context: ModelContext { container.mainContext }
    var settings: HouseholdSettings {
        var settings = HouseholdSettings()
        settings.timeZone = Self.timeZone
        return settings
    }

    func store() -> ReminderStore {
        ReminderStore(householdID: household, client: server.client, center: center.center, device: device, session: session,
                      context: context, now: { [self] in currentTime })
    }

    func wanted(me: Member? = nil) -> ReminderStore.Context {
        ReminderStore.Context(me: me ?? ann, members: [ann, kim], settings: settings)
    }

    func week(_ nights: [ReminderNight]? = nil, approved: Bool = true) -> ReminderWeek {
        ReminderWeek(planID: UUID(), start: Self.day(8), isApproved: approved, nights: nights ?? [night])
    }

    func set(now: Date) { currentTime = now }

    var prepID: String { ReminderID.prep(me: ann.id, night: night.id, meal: chili, step: 0) }
    var afterID: String { ReminderID.afterDinner(me: ann.id, night: night.id, meal: chili) }

    func records() throws -> [NotificationRecord] {
        try context.fetch(FetchDescriptor<NotificationRecord>())
    }
}

@MainActor
struct ReminderSchedulingTests {
    @Test func whatThePlannerSaysIsWhatGoesInAtTheRightTime() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        await test.store().replan(test.wanted())
        let ids = test.center.added.map(\.id)
        #expect(ids.contains(test.prepID))
        #expect(ids.contains(test.afterID))
        #expect(test.center.state.withLock { $0.intervals[test.prepID] } == Harness.at(9, 18).timeIntervalSince(Harness.at(8, 10)))
    }

    @Test func runningAgainChangesNothing() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        let first = test.center.pending.sorted()
        await store.replan(test.wanted())
        #expect(test.center.pending.sorted() == first)
        #expect(test.center.removed.isEmpty)
    }

    @Test func aDishThatChangedCancelsItsReminders() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        let tacos = UUID()
        var swapped = test.night
        swapped.mealID = tacos
        test.server.set(weeks: [test.week([swapped])])
        await store.replan(test.wanted())
        #expect(test.center.removed.contains(test.prepID))
        #expect(test.center.removed.contains(test.afterID))
        #expect(test.center.pending.contains(ReminderID.prep(me: test.ann.id, night: test.night.id, meal: tacos, step: 0)))
        #expect(try !test.records().contains { $0.key == test.prepID }, "called off, so it doesn't count")
    }

    @Test func aCookTimerIsNeverTouched() async throws {
        let test = try Harness()
        let timer = UUID().uuidString
        test.center.state.withLock { $0.pending = [timer, "foon.reminder.\(UUID().uuidString).after.gone"] }
        await test.store().replan(test.wanted())
        #expect(test.center.pending.contains(timer))
        #expect(!test.center.removed.contains(timer))
        #expect(test.center.removed.count == 1, "the stale reminder goes, with the same run")

        test.center.set(permission: .off)
        await test.store().replan(test.wanted())
        #expect(test.center.pending.contains(timer), "or when notifications are off")
    }

    @Test func aPreviousPersonsRemindersGoAndTheirRecordsDontCount() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        await test.store().replan(test.wanted())
        let anns = test.center.pending

        await test.store().replan(test.wanted(me: test.kim))
        #expect(Set(anns).isSubset(of: Set(test.center.removed)))
        #expect(test.center.pending == [ReminderID.afterDinner(me: test.kim.id, night: test.night.id, meal: test.chili)])
        #expect(try test.records().allSatisfy { $0.memberID == test.kim.id })
    }

    @Test func aFailedAddIsNotRecorded() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        test.center.state.withLock { $0.addFails = true }
        await test.store().replan(test.wanted())
        #expect(try test.records().isEmpty)
    }

    @Test func aRunAskedForDuringARunStillHappensAndLandsLast() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        let wanted = test.wanted()
        var swapped = test.night
        swapped.mealID = UUID()
        let newWeek = test.week([swapped])
        let server = test.server
        let parked = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        test.center.onAdd.withLock {
            $0 = {
                parked.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        let first = Task { await store.replan(wanted) }
        for await _ in parked.stream { break }
        server.set(weeks: [newWeek])
        await store.replan(wanted)
        release.continuation.finish()
        await first.value
        #expect(!test.center.pending.contains(test.prepID), "the older plan's reminder doesn't outlive the newer one")
        #expect(test.center.pending.contains(ReminderID.prep(me: test.ann.id, night: test.night.id, meal: swapped.mealID!, step: 0)))
    }
}

@MainActor
struct ReminderPermissionTests {
    @Test func withNotificationsOffNothingIsScheduledOrLogged() async throws {
        let test = try Harness()
        test.center.set(permission: .off)
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        #expect(test.center.added.isEmpty)
        #expect(try test.records().isEmpty)
        #expect(test.server.uploads.isEmpty)
        #expect(store.permission == .off)
        #expect(!store.shouldAsk, "only Settings can change a no")
    }

    @Test func turningThemOffCallsOffWhatsPending() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.center.set(permission: .off)
        await store.replan(test.wanted())
        #expect(test.center.pending.isEmpty)
        #expect(try test.records().isEmpty)
    }

    @Test func foonNeverAsksOnItsOwn() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        test.server.set(weeks: [test.week()])
        await test.store().replan(test.wanted())
        #expect(test.center.state.withLock { $0.requests } == 0)
        #expect(test.center.added.isEmpty)
    }

    @Test func aNewFamilyIsntAskedBeforeAWeekIsApproved() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        let store = test.store()
        await store.replan(test.wanted())
        #expect(!store.shouldAsk, "first launch: a planner has Time to plan to offer, and that's no reason to ask yet")

        test.server.set(weeks: [test.week(approved: false)])
        await store.replan(test.wanted())
        #expect(!store.shouldAsk, "a draft isn't either")

        test.server.set(weeks: [test.week()])
        await store.replan(test.wanted())
        #expect(store.shouldAsk)
    }

    @Test func someoneWithNothingToBeRemindedOfIsntAsked() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        var settings = test.settings
        settings.notificationPreset = .light
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(ReminderStore.Context(me: test.kim, members: [test.ann, test.kim], settings: settings))
        #expect(!store.shouldAsk)
    }

    @Test func notNowIsTheEndOfIt() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        store.decline(test.ann.id)
        #expect(!store.shouldAsk)

        let later = test.store()
        await later.replan(test.wanted())
        #expect(!later.shouldAsk, "a new launch doesn't bring it back")
        #expect(later.permission == .notAsked, "Family can still turn them on")
    }

    @Test func turningThemOnSchedulesWhatThereIs() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.center.set(permission: .on)
        await store.requestPermission(for: test.wanted())
        #expect(test.center.state.withLock { $0.requests } == 1)
        #expect(test.center.pending.contains(test.prepID))
        #expect(store.permission == .on)
    }
}

@MainActor
struct ReminderOfflineTests {
    @Test func offlineItPlansFromTheCache() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.server.set(offline: true)
        test.set(now: Harness.at(9, 10))
        await store.replan(test.wanted())
        #expect(test.center.pending.contains(test.prepID))
    }

    @Test func butNotOnceTheCacheIsTooOld() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.server.set(offline: true)
        test.set(now: Harness.at(10, 11))
        await store.replan(test.wanted())
        #expect(test.center.pending.isEmpty, "better nothing than a reminder about a week that may have changed")
    }

    @Test func aPhoneThatHasNeverReadThePlanSendsNothing() async throws {
        let test = try Harness()
        test.server.set(offline: true)
        await test.store().replan(test.wanted())
        #expect(test.center.added.isEmpty)
    }

    @Test func theCacheIsThereForTheNextLaunch() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        await test.store().replan(test.wanted())
        test.server.set(offline: true)
        await test.store().replan(test.wanted())
        #expect(test.center.pending.contains(test.prepID))
    }
}

@MainActor
struct ReminderLogTests {
    @Test func whatsScheduledIsLoggedAsTypeNightAndTimeOnly() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        await test.store().replan(test.wanted())
        let entry = try #require(test.server.uploads.first?.first { $0.type == "prep_reminder" })
        #expect(entry.nightID == test.night.id)
        #expect(entry.scheduledFor == Harness.at(9, 18))
        #expect(entry.sentAt == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(entry), encoding: .utf8) ?? ""
        #expect(!json.contains("Thaw"), "no text")
        let keys = try #require(try JSONSerialization.jsonObject(with: try encoder.encode(entry)) as? [String: Any]).keys
        #expect(Set(keys).isSubset(of: ["id", "type", "night_id", "scheduled_for", "sent_at", "responded_at", "response"]))
    }

    @Test func aRowSentOnceIsntSentAgainUntilItChanges() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        #expect(test.server.uploads.count == 1)
        await store.replan(test.wanted())
        #expect(test.server.uploads.count == 1)
    }

    @Test func offlineTheLogWaitsAndSchedulingDoesnt() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        test.server.set(uploadsFail: true)
        let store = test.store()
        await store.replan(test.wanted())
        #expect(test.center.pending.contains(test.prepID), "nothing waits for the log")
        #expect(test.server.uploads.isEmpty)
        test.server.set(uploadsFail: false)
        await store.replan(test.wanted())
        #expect(test.server.uploads.first?.contains { $0.type == "prep_reminder" } == true)
    }

    @Test func goneByAndNotPendingCountsAsSentOnce() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.center.state.withLock { $0.pending.removeAll { $0 == test.prepID } }
        test.center.state.withLock { $0.added = [] }
        test.set(now: Harness.at(9, 18, 30))
        await store.replan(test.wanted())
        #expect(!test.center.added.contains { $0.id == test.prepID }, "not sent again")
        let row = try #require(test.server.uploads.last?.first { $0.type == "prep_reminder" })
        #expect(row.sentAt == Harness.at(9, 18))
        #expect(try test.records().first { $0.key == test.prepID }?.history.sentAt == Harness.at(9, 18))
    }

    @Test func whatsBeenSentCountsAgainstTheBudgetAcrossRuns() async throws {
        let test = try Harness()
        // A kid on Balanced: five a week. Three have gone by the time she next opens the app.
        let nights = (8...14).map { day in
            ReminderNight(id: UUID(), date: Harness.day(day), mealID: UUID(),
                          attendance: [test.kim.id: true])
        }
        test.server.set(weeks: [test.week(nights)])
        test.set(now: Harness.at(8, 9))
        let store = test.store()
        await store.replan(test.wanted(me: test.kim))
        #expect(test.center.pending.count == 5)

        test.center.state.withLock { $0.pending = Array($0.pending.dropFirst(3)) }
        test.set(now: Harness.at(10, 20))
        await store.replan(test.wanted(me: test.kim))
        #expect(test.center.pending.count == 2, "not the five a fresh count would give")
    }

    @Test func oldRowsDropOffWhetherOrNotTheyGotThrough() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        test.server.set(uploadsFail: true)
        let store = test.store()
        await store.replan(test.wanted())
        #expect(try !test.records().isEmpty)
        test.center.state.withLock { $0.pending = [] }
        test.set(now: Harness.at(26, 10))
        await store.replan(test.wanted())
        #expect(try !test.records().contains { $0.key == test.prepID || $0.key == test.afterID })
    }
}

@MainActor
struct ReminderAnswerTests {
    @Test func doneIsFiledAndTheReminderIsOver() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        test.set(now: Harness.at(9, 18, 5))
        test.center.state.withLock { $0.pending.removeAll { $0 == test.prepID } }
        test.device.add(ReminderAnswer(id: test.prepID, response: "done", at: Harness.at(9, 18, 5)))
        await store.replan(test.wanted())
        let row = try #require(test.server.uploads.last?.first { $0.type == "prep_reminder" })
        #expect(row.response == "done")
        #expect(row.respondedAt == Harness.at(9, 18, 5))
        #expect(row.sentAt == Harness.at(9, 18, 5), "an answer means it arrived")
        #expect(test.device.answers.isEmpty)
    }

    @Test func aSnoozeStaysScheduledThroughARePlan() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        let until = Harness.at(9, 19, 5)
        test.set(now: Harness.at(9, 18, 5))
        test.device.add(ReminderAnswer(id: test.prepID, response: "snoozed", at: Harness.at(9, 18, 5), snoozedUntil: until))
        test.center.state.withLock { $0.added = [] }
        await store.replan(test.wanted())
        #expect(test.center.added.first { $0.id == test.prepID }?.fireAt == until)
        #expect(!test.center.removed.contains(test.prepID))
    }

    @Test func anAnswerFromSomeoneElsesReminderIsIgnored() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        test.device.add(ReminderAnswer(id: "foon.reminder.someone.prep.x", response: "done", at: Harness.at(8, 9)))
        await test.store().replan(test.wanted())
        #expect(test.device.answers.isEmpty)
        #expect(test.server.uploads.first?.allSatisfy { $0.response == nil } == true)
    }

    private let night = UUID()
    private let day = Harness.day(10)
    private var id: String { ReminderID.prep(me: UUID(), night: night, meal: UUID(), step: 0) }

    @Test func aCookTimerAnswerIsntOurs() {
        #expect(ReminderResponse.outcome(id: UUID().uuidString, action: "default", payload: nil, now: .now) == nil)
    }

    @Test func tappingOpensTheRightPlaceAndCallsOffTheFollowUp() throws {
        let id = id
        let payload = ReminderPayload(route: .night(night, day), dinnerAt: nil)
        let outcome = try #require(ReminderResponse.outcome(id: id, action: "tap", payload: payload, now: .now))
        #expect(outcome.route == .night(night, day))
        #expect(outcome.answer.response == "opened")
        #expect(outcome.cancels == [ReminderID.followUp(of: id)])
        #expect(!outcome.schedulesAgain)
    }

    @Test func doneOpensNothing() throws {
        let payload = ReminderPayload(route: .night(night, day), dinnerAt: nil)
        let outcome = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.doneAction, payload: payload, now: .now))
        #expect(outcome.route == nil)
        #expect(outcome.answer.response == "done")
    }

    @Test func swapGoesToSwap() throws {
        let payload = ReminderPayload(route: .night(night, day), dinnerAt: nil)
        let outcome = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.swapAction, payload: payload, now: .now))
        #expect(outcome.route == .swap(night, day))
    }

    @Test func aSnoozeComesBackInAnHourIfDinnerAllows() throws {
        let now = Harness.at(9, 16)
        let inTime = ReminderPayload(route: .night(night, day), dinnerAt: Harness.at(9, 18))
        let snoozed = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.snoozeAction, payload: inTime, now: now))
        #expect(snoozed.schedulesAgain)
        #expect(snoozed.answer.snoozedUntil == Harness.at(9, 17))
        #expect(snoozed.route == nil)

        let tooLate = ReminderPayload(route: .night(night, day), dinnerAt: Harness.at(9, 16, 30))
        let late = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.snoozeAction, payload: tooLate, now: now))
        #expect(!late.schedulesAgain)
        #expect(late.answer.snoozedUntil == nil)
    }

    @Test func answeringAFollowUpAnswersWhatItFollowed() throws {
        let id = id
        let outcome = try #require(ReminderResponse.outcome(id: ReminderID.followUp(of: id), action: ReminderCenter.doneAction,
                                                            payload: nil, now: .now))
        #expect(outcome.answer.id == id)
    }

    @Test func aPayloadSurvivesTheNotification() {
        let dinner = Date(timeIntervalSince1970: 1_800_000_000)
        for route in [ReminderRoute.week(day), .night(night, day), .dinnerCard] {
            let payload = ReminderPayload(route: route, dinnerAt: dinner)
            #expect(ReminderPayload(userInfo: payload.userInfo) == payload)
        }
        #expect(ReminderPayload(userInfo: [:]) == nil)
        #expect(ReminderPayload(userInfo: ["route": "night"]) == nil)
    }

    @Test func aPayloadCarriesNoWords() {
        let keys = Set(ReminderPayload(route: .night(night, day), dinnerAt: .now).userInfo.keys)
        #expect(keys == ["route", "night", "date", "dinner"])
    }
}

@MainActor
struct ReminderSignOutTests {
    @Test func signingOutClearsTheDeviceAndAnyoneNextGetsNothingOfTheirs() async throws {
        let test = try Harness()
        test.center.set(permission: .notAsked)
        test.server.set(weeks: [test.week()])
        let store = test.store()
        await store.replan(test.wanted())
        store.decline(test.ann.id)
        test.device.add(ReminderAnswer(id: test.prepID, response: "done", at: .now))

        ReminderStore.clearDevice(center: test.center.center, device: test.device, session: test.session)
        try SyncService.clearCache(in: test.context)

        #expect(test.center.state.withLock { $0.clears } == 1)
        #expect(test.device.answers.isEmpty)
        #expect(!test.device.hasDeclined(test.ann.id))
        #expect(try test.context.fetch(FetchDescriptor<CachedReminders>()).isEmpty)
        #expect(try test.records().isEmpty)

        test.server.set(offline: true)
        test.center.set(permission: .on)
        await test.store().replan(test.wanted(me: test.kim))
        #expect(test.center.added.isEmpty, "the cached plan went too, so there's nothing to plan from")
    }

    @Test func aRunStillGoingWhenTheyLeaveLeavesNothingBehind() async throws {
        let test = try Harness()
        test.server.set(weeks: [test.week()])
        let store = test.store()
        let wanted = test.wanted()
        let center = test.center, device = test.device, session = test.session
        // Sign-out lands while the first reminder is going in.
        test.center.onAdd.withLock {
            $0 = {
                await MainActor.run {
                    ReminderStore.clearDevice(center: center.center, device: device, session: session)
                }
            }
        }
        await store.replan(wanted)
        #expect(test.center.pending.isEmpty)
        #expect(try test.records().isEmpty)
        #expect(test.server.uploads.isEmpty)

        await store.replan(wanted)
        #expect(test.center.pending.isEmpty, "that store is finished")
    }

    @Test func clearingTheCacheCoversReminders() throws {
        let test = try Harness()
        test.context.insert(CachedReminders(householdID: test.household, payload: Data()))
        try test.context.save()
        try SyncService.clearCache(in: test.context)
        #expect(try test.context.fetch(FetchDescriptor<CachedReminders>()).isEmpty)
    }

    @Test func anotherHouseholdsAreRemovedWithTheirWeek() throws {
        let test = try Harness()
        let other = UUID()
        test.context.insert(CachedReminders(householdID: other, payload: Data()))
        let reminder = PlannedReminder(id: "foon.reminder.x", kind: .prep, nightID: nil, fireAt: .now, dinnerAt: nil, title: "", body: "",
                                       route: .dinnerCard)
        test.context.insert(NotificationRecord(reminder: reminder, householdID: other, memberID: UUID()))
        try test.context.save()
        _ = SyncService(householdID: test.household, context: test.context, client: .preview)
        #expect(try test.context.fetch(FetchDescriptor<CachedReminders>()).isEmpty)
        #expect(try test.records().isEmpty)
    }

    /// An older app's store on disk: the new models must open it, or the offline cache would quietly go in-memory.
    @Test func anExistingCacheOpensWithTheNewModels() throws {
        let folder = URL.temporaryDirectory.appending(path: "foon-reminder-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "cache.store")
        let plan = PlanRow(id: UUID(), householdID: UUID(), weekStart: Harness.day(8), approvedAt: nil)
        do {
            let older = Schema([CachedPlan.self, CachedNight.self, CachedListItem.self, CachedItem.self, PendingChange.self])
            let container = try ModelContainer(for: older, configurations: ModelConfiguration(schema: older, url: url))
            let context = ModelContext(container)
            context.insert(CachedPlan(plan))
            try context.save()
        }
        let container = try ModelContainer(for: SyncService.schema, configurations: ModelConfiguration(schema: SyncService.schema, url: url))
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<CachedPlan>()).map(\.id) == [plan.id])
        context.insert(CachedReminders(householdID: plan.householdID, payload: Data()))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<CachedReminders>()).count == 1)
    }

    @Test func aMembersBadPrefsDontCostTheMember() throws {
        let row = """
        {"id": "00000000-0000-0000-0000-0000000000a1", "household_id": "00000000-0000-0000-0000-0000000000a0",
         "first_name": "Nora", "role": "member", "status": "active", "age_group": "kid", "guardian": false,
         "notification_prefs": "nonsense"}
        """
        let member = try JSONDecoder().decode(Member.self, from: Data(row.utf8))
        #expect(member.firstName == "Nora")
        #expect(member.notificationPrefs?.preset == nil)
    }
}

/// The picker's words are promises, so they say what's on the way and don't claim it's here.
struct ReminderPresetWordingTests {
    @Test func theySayWhatWorksAndWhatDoesnt() {
        let light = HouseholdSettings.NotificationPreset.light.summary
        #expect(light.contains("time to plan"))
        #expect(light.contains("prep reminders"))
        #expect(light.contains("on the way"), "the plan's set and urgent items need server push")
        let balanced = HouseholdSettings.NotificationPreset.balanced.summary
        #expect(balanced.contains("after-dinner"))
        #expect(balanced.contains("check-in"))
        #expect(balanced.contains("on the way"), "the check-in is #41")
        let engaged = HouseholdSettings.NotificationPreset.engaged.summary
        #expect(engaged.contains("follow-up"))
        #expect(engaged.contains("on the way"))
    }
}
