import Foundation
import Synchronization
import Testing
@testable import Foon

struct HouseholdSettingsTests {
    @Test func missingSettingsUseTheDefaults() throws {
        let settings = try JSONDecoder().decode(HouseholdSettings.self, from: Data("{}".utf8))
        #expect(settings == HouseholdSettings())
        #expect(settings.weekStart == 7, "Sunday, the usual shopping day")
        #expect(settings.dinnerTime == "18:00")
        #expect(settings.repeatWindowDays == 10)
    }

    @Test func storedSettingsOverrideOnlyWhatTheySet() throws {
        let json = #"{"week_start": 6, "dinner_time": "17:30", "takeout_nights": 1, "something_new": true}"#
        let settings = try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
        #expect(settings.weekStart == 6)
        #expect(settings.dinnerTime == "17:30")
        #expect(settings.takeoutNights == 1)
        #expect(settings.leftoverNights == HouseholdSettings().leftoverNights)
    }

    @Test func anOutOfRangeWeekStartFallsBackToSunday() throws {
        let settings = try JSONDecoder().decode(HouseholdSettings.self, from: Data(#"{"week_start": 9}"#.utf8))
        #expect(settings.weekStart == 7)
    }

    @Test func aHouseholdWithoutSettingsHasTheDefaults() throws {
        let json = #"{"id": "00000000-0000-0000-0000-0000000000a0", "name": "The Smiths", "emoji": null, "owner": null}"#
        let household = try JSONDecoder().decode(Household.self, from: Data(json.utf8))
        #expect(household.planningSettings == HouseholdSettings())
    }
}

struct WeekMathTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    @Test(arguments: [
        (CalendarDay(year: 2026, month: 11, day: 1), 7, CalendarDay(year: 2026, month: 11, day: 1)),  // Sunday itself
        (CalendarDay(year: 2026, month: 11, day: 4), 7, CalendarDay(year: 2026, month: 11, day: 1)),  // Wednesday
        (CalendarDay(year: 2026, month: 11, day: 7), 7, CalendarDay(year: 2026, month: 11, day: 1)),  // Saturday
        (CalendarDay(year: 2026, month: 11, day: 4), 6, CalendarDay(year: 2026, month: 10, day: 31)), // Saturday start
        (CalendarDay(year: 2026, month: 11, day: 2), 1, CalendarDay(year: 2026, month: 11, day: 2))   // Monday start
    ])
    func theWeekStartsOnTheMostRecentShoppingDay(day: CalendarDay, weekStart: Int, expected: CalendarDay) {
        #expect(WeekMath.start(of: day, weekStart: weekStart, calendar: calendar) == expected)
    }

    @Test func isoWeekdaysRunMondayToSunday() {
        #expect(WeekMath.isoWeekday(of: CalendarDay(year: 2026, month: 11, day: 2), calendar: calendar) == 1)
        #expect(WeekMath.isoWeekday(of: CalendarDay(year: 2026, month: 11, day: 1), calendar: calendar) == 7)
    }

    @Test func weekdayNamesFollowTheMondayFirstOrder() {
        #expect(WeekMath.weekdays.map(\.iso) == [1, 2, 3, 4, 5, 6, 7])
    }
}

struct AttendanceDefaultsTests {
    @Test func membersDecodeTheirUsualNightsAway() throws {
        let json = #"""
        {"id": "00000000-0000-0000-0000-0000000000a3", "household_id": "00000000-0000-0000-0000-0000000000a0",
         "first_name": "Owen", "avatar": null, "age_group": "kid", "guardian": false, "role": "member",
         "status": "active", "away_until": null, "user_id": null,
         "attendance_defaults": {"usually_away": [1, 2, 3, 4]}}
        """#
        let owen = try JSONDecoder().decode(Member.self, from: Data(json.utf8))
        #expect(owen.usuallyAway == [1, 2, 3, 4])
    }

    @Test func aChangedScheduleIsSentAsAttendanceDefaults() throws {
        let owen = Member.fixture(firstName: "Owen")
        var draft = MemberDraft(owen)
        draft.usuallyAway = [4, 1, 2]
        let changes = draft.changes(from: owen)
        #expect(String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)
            == #"{"attendance_defaults":{"usually_away":[1,2,4]}}"#)
        #expect(owen.applying(changes).usuallyAway == [1, 2, 4])
    }

    @Test func everyoneCanEditTheirOwnScheduleAndParentsAnyones() {
        #expect(HouseholdStore.EditScope.avatarOnly.schedule)
        #expect(HouseholdStore.EditScope.nameAndAvatar.schedule)
        #expect(HouseholdStore.EditScope.everything.schedule)
        #expect(!HouseholdStore.EditScope.none.schedule)
    }
}

@MainActor
struct WeekStoreTests {
    private let household = Household.sample.id
    private let ann = Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: .previewUser)
    private let owen = Member.fixture(firstName: "Owen", avatar: "🦊", ageGroup: .kid)
    private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

    private func week(effort: NightEffort = .normal, owenHome: Bool = true) -> Week {
        Week(planID: UUID(), start: sunday, approvedAt: nil, nights: (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: effort, dinnerTime: "18:00",
                      mealID: nil, mealName: nil, quickPick: nil, locked: false,
                      attendance: [ann.id: true, owen.id: owenHome])
        })
    }

    @Test func loadsThisWeekFromTheShoppingDay() async {
        let requested = Mutex<CalendarDay?>(nil)
        let existing = week()
        let store = WeekStore(householdID: household, client: .fake(week: { _, start in
            requested.withLock { $0 = start }
            return existing
        }), today: { CalendarDay(year: 2026, month: 11, day: 4) })
        await store.load(settings: HouseholdSettings())
        #expect(requested.withLock { $0 } == sunday)
        #expect(store.week == existing)
    }

    @Test func nextWeekStartsSevenDaysLater() async {
        let requested = Mutex<CalendarDay?>(nil)
        let store = WeekStore(householdID: household, client: .fake(week: { _, start in
            requested.withLock { $0 = start }
            return nil
        }), today: { CalendarDay(year: 2026, month: 11, day: 4) })
        store.showingNextWeek = true
        await store.load(settings: HouseholdSettings())
        #expect(requested.withLock { $0 } == CalendarDay(year: 2026, month: 11, day: 8))
        #expect(store.week == nil)
    }

    @Test func startingAWeekCreatesItForTheShownStartDay() async {
        let created = week()
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in nil },
            create: { householdID, start in
                #expect(householdID == household)
                #expect(start == sunday)
                return created
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.startWeek()
        #expect(store.week == created)
    }

    @Test func togglingAttendanceShowsAtOnceAndIsSent() async {
        let sent = Mutex<(UUID, UUID, Bool)?>(nil)
        let existing = week()
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in existing },
            setExpected: { night, member, expected in sent.withLock { $0 = (night, member, expected) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let monday = existing.nights[1]
        await store.toggleAttendance(nightID: monday.id, memberID: owen.id)
        #expect(store.week?.nights[1].attendance[owen.id] == false)
        #expect(sent.withLock { $0?.0 } == monday.id)
        #expect(sent.withLock { $0?.2 } == false)
    }

    @Test func aFailedToggleShowsTheServersWeekAndSaysSo() async {
        let existing = week()
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in existing },
            setExpected: { _, _, _ in throw URLError(.notConnectedToInternet) }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.toggleAttendance(nightID: existing.nights[1].id, memberID: owen.id)
        #expect(store.week?.nights[1].attendance[owen.id] == true)
        #expect(store.errorMessage != nil)
    }

    @Test func theEffortChipCyclesAndIsSent() async {
        let sent = Mutex<[NightEffort]>([])
        let existing = week(effort: .event)
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in existing },
            setEffort: { _, effort in sent.withLock { $0.append(effort) } }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.cycleEffort(nightID: existing.nights[0].id)
        #expect(store.week?.nights[0].effort == .normal)
        #expect(sent.withLock { $0 } == [.normal])
    }

    @Test func aDoubleTapStartsTheWeekOnce() async {
        let gate = AsyncStream<Void>.makeStream()
        let creates = Mutex(0)
        let created = week()
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in nil },
            create: { _, _ in
                creates.withLock { $0 += 1 }
                for await _ in gate.stream { break }
                return created
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        async let first: Void = store.startWeek()
        while creates.withLock({ $0 }) == 0 { await Task.yield() }
        #expect(store.isStarting)
        await store.startWeek()
        gate.continuation.yield()
        await first
        #expect(creates.withLock { $0 } == 1)
        #expect(store.week == created)
    }

    @Test func aWeekStartedBeforeSwitchingWeeksDoesNotLandOnTheOtherWeek() async {
        let gate = AsyncStream<Void>.makeStream()
        let creating = Mutex(false)
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in nil },
            create: { _, start in
                creating.withLock { $0 = true }
                for await _ in gate.stream { break }
                return Week(planID: UUID(), start: start, approvedAt: nil, nights: [])
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        async let starting: Void = store.startWeek()
        while !creating.withLock({ $0 }) { await Task.yield() }
        store.showingNextWeek = true
        await store.load(settings: HouseholdSettings())
        gate.continuation.yield()
        await starting
        #expect(store.week == nil, "next week is showing, and it hasn't been started")
    }

    @Test func aCancelledLoadIsNotAnError() async {
        let store = WeekStore(householdID: household, client: .fake(week: { _, _ in throw URLError(.cancelled) }),
                              today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(store.errorMessage == nil)
    }

    @Test func someoneWithoutNightsIsFilledInWhenAPlannerOpensTheWeek() async {
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let creates = Mutex(0)
        let existing = week()
        var filled = existing
        for index in filled.nights.indices { filled.nights[index].attendance[nora.id] = true }
        let complete = filled
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in existing },
            create: { _, _ in
                creates.withLock { $0 += 1 }
                return complete
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        await store.fillInMissing(members: [ann, owen, nora, .fixture(firstName: "Gone", status: .removed)])
        #expect(creates.withLock { $0 } == 1)
        #expect(store.week == complete)
        await store.fillInMissing(members: [ann, owen, nora])
        #expect(creates.withLock { $0 } == 1, "nothing missing, nothing sent")
    }

    @Test func rapidTapsOnOneNightAreSentInOrder() async {
        let sent = Mutex<[NightEffort]>([])
        let existing = week()
        let store = WeekStore(householdID: household, client: .fake(
            week: { _, _ in existing },
            setEffort: { _, effort in
                // The first request is the slowest, so unordered sends would land out of order.
                if effort == .rushed { try await Task.sleep(for: .milliseconds(50)) }
                sent.withLock { $0.append(effort) }
            }
        ), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let night = existing.nights[0].id
        async let one: Void = store.cycleEffort(nightID: night)
        async let two: Void = store.cycleEffort(nightID: night)
        async let three: Void = store.cycleEffort(nightID: night)
        _ = await (one, two, three)
        #expect(store.week?.nights[0].effort == .event)
        #expect(sent.withLock { $0 } == [.rushed, .full, .event])
    }

    @Test func cardsShowWhoIsHomeInFamilyOrder() async {
        let existing = week(owenHome: false)
        let store = WeekStore(householdID: household, client: .fake(week: { _, _ in existing }), today: { sunday })
        await store.load(settings: HouseholdSettings())
        let cards = store.cards(members: [ann, owen])
        #expect(cards.count == 7)
        #expect(cards[0].date == sunday)
        #expect(cards[0].attendance.map(\.firstName) == ["Ann", "Owen"])
        #expect(cards[0].attendance.map(\.isHome) == [true, false])
        #expect(cards[0].slot == .empty)
    }

    @Test func aPlannedNightShowsItsMealOrQuickPick() {
        var night = week().nights[0]
        night.mealID = UUID()
        night.mealName = "Tacos"
        #expect(WeekStore.slot(for: night, sides: ["salad"]) == .meal(name: "Tacos", photoURL: nil, reason: nil,
                                                                   sides: ["salad"]))
        night.mealID = nil
        night.mealName = nil
        night.quickPick = .takeout
        #expect(WeekStore.slot(for: night, sides: []) == .quickPick(.takeout))
    }

    @Test func membersWithoutARowThatNightAreLeftOff() async {
        var partial = week()
        partial.nights[0].attendance = [ann.id: true]
        let existing = partial
        let store = WeekStore(householdID: household, client: .fake(week: { _, _ in existing }), today: { sunday })
        await store.load(settings: HouseholdSettings())
        #expect(store.cards(members: [ann, owen])[0].attendance.map(\.firstName) == ["Ann"])
    }
}

extension WeekClient {
    static func fake(
        week: @escaping @Sendable (UUID, CalendarDay) async throws -> Week? = { _, _ in nil },
        create: @escaping @Sendable (UUID, CalendarDay) async throws -> Week = { _, _ in throw URLError(.unknown) },
        setExpected: @escaping @Sendable (UUID, UUID, Bool) async throws -> Void = { _, _, _ in },
        setEffort: @escaping @Sendable (UUID, NightEffort) async throws -> Void = { _, _ in },
        setLocked: @escaping @Sendable (UUID, Bool) async throws -> Void = { _, _ in },
        setNights: @escaping @Sendable (UUID, [NightUpdate]) async throws -> Void = { _, _ in },
        setNight: @escaping @Sendable (NightUpdate, Bool) async throws -> Void = { _, _ in },
        approve: @escaping @Sendable (UUID, [WeeklyList.Line]) async throws -> Void = { _, _ in },
        traditions: @escaping @Sendable (UUID) async throws -> [Tradition] = { _ in [] },
        setTradition: @escaping @Sendable (UUID, Int, Tradition?) async throws -> Void = { _, _, _ in }
    ) -> WeekClient {
        WeekClient(week: week, create: create, setExpected: setExpected, setEffort: setEffort, setLocked: setLocked,
                   setNights: setNights, setNight: setNight, approve: approve, traditions: traditions,
                   setTradition: setTradition)
    }
}
