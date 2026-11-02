import Foundation
import Supabase
import Testing
@testable import Foon

private typealias F = PlannerFixture

/// The check-in as a notification.
@Suite struct CheckInReminderTests {
    private func checkIns(me: Member = F.ann, settings: HouseholdSettings = F.settings, nights: [ReminderNight],
                          approved: Bool = true, history: [ReminderHistory] = [], now: Date = F.at(8, 10)) -> [PlannedReminder] {
        F.of(.checkIn, F.plan(me: me, settings: settings, weeks: [F.week(nights, approved: approved)], history: history, now: now))
    }

    private func home(_ day: Int, meal: UUID? = F.chili) -> ReminderNight {
        var night = F.night(day, meal: meal)
        night.attendance = Dictionary(uniqueKeysWithValues: F.family.map { ($0.id, true) })
        return night
    }

    @Test func itGoesAtTheHouseholdsTimeToEveryoneExpected() throws {
        let reminder = try #require(checkIns(nights: [home(8)]).first)
        #expect(reminder.fireAt == F.at(8, 15, 30))
        #expect(reminder.title == ReminderText.checkInTitle)
        #expect(reminder.route == .checkIn(night: reminder.nightID!, member: F.ann.id))
    }

    @Test func aPlannerCanMoveIt() throws {
        var settings = F.settings
        settings.checkInTime = "16:15"
        #expect(try #require(checkIns(settings: settings, nights: [home(8)]).first).fireAt == F.at(8, 16, 15))
    }

    @Test func lightDoesntAsk() {
        var settings = F.settings
        settings.notificationPreset = .light
        #expect(checkIns(settings: settings, nights: [home(8)]).isEmpty)
    }

    @Test func notForSomeoneNotExpected() {
        var night = home(8)
        night.attendance[F.ann.id] = false
        #expect(checkIns(nights: [night]).isEmpty)
        night.attendance[F.ann.id] = nil
        #expect(checkIns(nights: [night]).isEmpty, "no row: added after the week was made")
    }

    @Test func notOnceTheyveAnsweredOnAnyPhone() {
        var night = home(8)
        night.checkedIn = [F.ann.id]
        #expect(checkIns(nights: [night]).isEmpty)
    }

    @Test func notForAnUnapprovedWeekOrAnEmptyNightOrFendForYourselves() {
        #expect(checkIns(nights: [home(8)], approved: false).isEmpty)
        #expect(checkIns(nights: [home(8, meal: nil)]).isEmpty)
        var fend = home(8, meal: nil)
        fend.quickPick = .fendForYourselves
        #expect(checkIns(nights: [fend]).isEmpty)
        var takeout = home(8, meal: nil)
        takeout.quickPick = .takeout
        #expect(checkIns(nights: [takeout]).count == 1, "takeout still needs a head count")
    }

    @Test func notOnceDinnersLogged() {
        var night = home(8)
        night.hasLog = true
        #expect(checkIns(nights: [night]).isEmpty)
    }

    @Test func notOnceItsTooLateOrAfterDinner() {
        #expect(checkIns(nights: [home(8)], now: F.at(8, 16)).isEmpty, "the time's gone by")
        var settings = F.settings
        settings.checkInTime = "18:00"
        #expect(checkIns(settings: settings, nights: [home(8)]).isEmpty, "at dinner is too late to matter")
    }

    @Test func noFollowUpEvenOnEngaged() {
        var settings = F.settings
        settings.notificationPreset = .engaged
        #expect(checkIns(settings: settings, nights: [home(8)]).count == 1, "no answer means home")
    }

    @Test func kidsAreAskedAfterSchoolEvenIfItsSetEarlier() throws {
        var settings = F.settings
        settings.checkInTime = "10:00"
        // The 9th is a Monday.
        let reminder = try #require(checkIns(me: F.kim, settings: settings, nights: [home(9)]).first)
        #expect(reminder.fireAt == F.at(9, 15))
        #expect(try #require(checkIns(settings: settings, nights: [home(9)]).first).fireAt == F.at(9, 10), "adults at the time set")
    }

    @Test func aKidsBudgetSharesOutNightByNight() {
        let nights = (8...14).map { home($0) }
        let plan = F.plan(me: F.kim, weeks: [F.week(nights)])
        #expect(plan.count == 5)
        #expect(!F.of(.checkIn, plan).isEmpty && !F.of(.afterDinner, plan).isEmpty, "not all one kind")
    }
}

@Suite struct ReminderSnapshotCheckInTests {
    @Test func aSnapshotCachedBeforeCheckInsStillReads() throws {
        let night = F.night(8)
        let snapshot = ReminderSnapshot(pulledAt: F.at(8, 9), weeks: [F.week([night])])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var weeks = try #require(json["weeks"] as? [[String: Any]])
        var nights = try #require(weeks[0]["nights"] as? [[String: Any]])
        nights[0]["checkedIn"] = nil
        weeks[0]["nights"] = nights
        json["weeks"] = weeks
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(ReminderSnapshot.self, from: old).weeks[0].nights == [night])
    }

    @Test func anAnswerStillWaitingCountsWhenPlanning() {
        let night = F.night(8)
        let snapshot = ReminderSnapshot(pulledAt: F.at(8, 9), weeks: [F.week([night])])
            .applying([CheckInAnswer(nightID: night.id, memberID: F.ann.id, home: false)])
        let plan = F.plan(weeks: snapshot.weeks)
        #expect(F.of(.checkIn, plan).isEmpty, "they've answered")
        #expect(F.of(.afterDinner, plan).isEmpty, "and said they'd miss it")
    }

    @Test func theLastAnswerWins() {
        let night = F.night(8)
        let waiting = [false, true].map { CheckInAnswer(nightID: night.id, memberID: F.ann.id, home: $0) }
        let applied = ReminderSnapshot(pulledAt: F.at(8, 9), weeks: [F.week([night])]).applying(waiting)
        #expect(applied.weeks[0].nights[0].attendance[F.ann.id] == true)
    }
}

/// Answering it from the lock screen.
@Suite struct CheckInAnswerTests {
    private let night = UUID()
    private let member = UUID()

    private func outcome(_ action: String) -> ReminderResponse.Outcome? {
        ReminderResponse.outcome(id: ReminderID.checkIn(me: member, night: night), action: action,
                                 payload: ReminderPayload(route: .checkIn(night: night, member: member), dinnerAt: nil), now: .now)
    }

    @Test func homeAndNotHomeSaySoWithoutOpeningTheApp() throws {
        let home = try #require(outcome(ReminderCenter.homeAction))
        #expect(home.checkIn == CheckInAnswer(nightID: night, memberID: member, home: true))
        #expect(home.route == nil)
        #expect(home.answer.response == "done")
        #expect(try #require(outcome(ReminderCenter.notHomeAction)).checkIn?.home == false)
    }

    @Test func tappingItOpensTheCardWithoutAnswering() throws {
        let tapped = try #require(outcome("com.apple.UNNotificationDefaultActionIdentifier"))
        #expect(tapped.checkIn == nil)
        #expect(tapped.route == .checkIn(night: night, member: member))
    }

    @Test func itsPayloadSurvivesTheTrip() {
        let payload = ReminderPayload(route: .checkIn(night: night, member: member), dinnerAt: nil)
        #expect(ReminderPayload(userInfo: payload.userInfo) == payload)
        #expect(ReminderPayload(userInfo: ["route": "checkin", "night": night.uuidString]) == nil)
    }

    @Test func itHasItsOwnButtons() {
        let reminder = PlannedReminder(id: "x", kind: .checkIn, nightID: night, fireAt: .now, dinnerAt: nil, title: "", body: "",
                                       route: .checkIn(night: night, member: member))
        #expect(ReminderCenter.category(for: reminder) == ReminderCenter.checkInCategory)
    }

    @Test func afterDinnerPromptsForThatNightAreRecognized() {
        let id = ReminderID.afterDinner(me: member, night: night, meal: UUID())
        #expect(ReminderID.isAfterDinner(id, night: night))
        #expect(!ReminderID.isAfterDinner(id, night: UUID()))
        #expect(!ReminderID.isAfterDinner(ReminderID.checkIn(me: member, night: night), night: night))
    }
}

@Suite @MainActor struct CheckInDeliveryTests {
    private actor Sent {
        var answers: [Bool] = []
        func add(_ home: Bool) { answers.append(home) }
    }

    private func device() -> ReminderDevice {
        ReminderDevice(defaults: UserDefaults(suiteName: "checkin.\(UUID().uuidString)")!)
    }

    private func answer(_ home: Bool) -> CheckInAnswer { CheckInAnswer(nightID: UUID(), memberID: UUID(), home: home) }

    private func client(_ work: @escaping @Sendable (Bool) async throws -> Void) -> NotificationClient {
        var client = NotificationClient.preview
        client.answerCheckIn = { _, _, home in try await work(home) }
        return client
    }

    @Test func theyGoInOrderAndComeOffTheList() async {
        let device = device(), sent = Sent()
        device.add(answer(false))
        device.add(answer(true))
        await CheckInDelivery.send(device: device, client: client { await sent.add($0) })
        #expect(await sent.answers == [false, true])
        #expect(device.checkIns.isEmpty)
    }

    @Test func noSignalKeepsThemForNextTime() async {
        let device = device(), first = answer(false), second = answer(true)
        device.add(first)
        device.add(second)
        await CheckInDelivery.send(device: device, client: client { _ in throw URLError(.notConnectedToInternet) })
        #expect(device.checkIns == [first, second])
    }

    @Test func aFinalNoComesOffTheListAndTheRestStillGo() async {
        let device = device(), sent = Sent()
        device.add(answer(false))
        device.add(answer(true))
        await CheckInDelivery.send(device: device, client: client { home in
            if !home { throw PostgrestError(code: "22023", message: "the check-in is only for tonight") }
            await sent.add(home)
        })
        #expect(await sent.answers == [true])
        #expect(device.checkIns.isEmpty)
    }

    @Test func notAllowedIsntFinal() async {
        // What a phone sees before its session is back: losing the answer would leave the planner cooking for them.
        let device = device(), waiting = answer(false)
        device.add(waiting)
        await CheckInDelivery.send(device: device, client: client { _ in
            throw PostgrestError(code: "42501", message: "permission denied")
        })
        #expect(device.checkIns == [waiting])
    }

    @Test func theCardsAnswerReplacesOneStillWaiting() {
        let device = device(), night = UUID(), member = UUID(), other = answer(true)
        device.add(CheckInAnswer(nightID: night, memberID: member, home: true))
        device.add(other)
        device.removeCheckIns(night: night, member: member)
        #expect(device.checkIns == [other])
    }

    @Test func signingOutClearsThem() {
        let device = device()
        device.add(answer(false))
        device.clear()
        #expect(device.checkIns.isEmpty)
    }
}

/// The card and the planner's note.
@Suite struct DayOfCheckInTests {
    private let calendar = F.calendar
    private let bob: Member = F.kim
    private let me: Member = F.ann
    private var settings: HouseholdSettings { F.settings }

    private func night(day: Int = 8, meal: UUID? = F.chili, pick: QuickPick? = nil, expected: Bool = true, checkedIn: Set<UUID> = [],
                       reason: String? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: F.day(day), effort: .normal, dinnerTime: "18:00", mealID: meal, mealName: meal.map { _ in "Chili" },
                  quickPick: pick, locked: false, attendance: [me.id: expected, bob.id: expected], checkedIn: checkedIn, reason: reason)
    }

    private func asking(_ night: WeekNight, logs: [DinnerLog] = [], approved: Bool = true, at now: Date = F.at(8, 16)) -> WeekNight? {
        DayOfCheckIn.asking(me, nights: [night], logs: logs, settings: settings, isApproved: approved, now: now, calendar: calendar)
    }

    @Test func theCardShowsFromTheCheckInTimeUntilDinner() {
        let tonight = night()
        #expect(asking(tonight, at: F.at(8, 15, 29)) == nil)
        #expect(asking(tonight, at: F.at(8, 15, 30)) == tonight)
        #expect(asking(tonight, at: F.at(8, 17, 59)) == tonight)
        #expect(asking(tonight, at: F.at(8, 18)) == nil)
    }

    @Test func notAfterTheyveAnsweredOrIfTheyreNotExpected() {
        #expect(asking(night(checkedIn: [me.id])) == nil)
        #expect(asking(night(expected: false)) == nil)
    }

    @Test func notForAnUnapprovedWeekAnOtherDayOrALoggedNight() {
        let tonight = night()
        #expect(asking(tonight, approved: false) == nil)
        #expect(asking(night(day: 9)) == nil)
        #expect(asking(tonight, logs: [DinnerLog(id: UUID(), nightID: tonight.id, date: tonight.date, mealID: F.chili, mealName: "Chili",
                                                 quickPick: nil)]) == nil)
    }

    @Test func someoneWhoSaidNoCanTakeItBackUntilDinner() {
        let out = night(expected: false, checkedIn: [me.id])
        func said(at now: Date) -> WeekNight? {
            DayOfCheckIn.saidNotHome(me, nights: [out], logs: [], settings: settings, isApproved: true, now: now, calendar: calendar)
        }
        #expect(said(at: F.at(8, 16)) == out)
        #expect(said(at: F.at(8, 18)) == nil)
        #expect(DayOfCheckIn.saidNotHome(me, nights: [night(expected: false)], logs: [], settings: settings, isApproved: true,
                                         now: F.at(8, 16), calendar: calendar) == nil, "a planner marked them out: nothing they said")
    }

    private func changes(_ night: WeekNight, canPlan: Bool = true, dismissed: Set<String> = []) -> [DayOfCheckIn.Change] {
        DayOfCheckIn.changes(nights: [night], members: [me, bob], me: me.id, canPlan: canPlan, today: F.day(8), dismissed: dismissed)
    }

    private func bobOut(meal: UUID? = F.chili, pick: QuickPick? = nil, reason: String? = nil) -> WeekNight {
        var out = night(meal: meal, pick: pick, checkedIn: [bob.id], reason: reason)
        out.attendance[bob.id] = false
        return out
    }

    @Test func aPlannerHearsOnlyAboutANo() {
        #expect(changes(night()).isEmpty, "no answer means home")
        #expect(changes(night(checkedIn: [bob.id])).isEmpty, "a yes changes nothing")
        var markedOut = night()
        markedOut.attendance[bob.id] = false
        #expect(changes(markedOut).isEmpty, "the planner marked them out: nothing they said")
        #expect(changes(bobOut()).map(\.member.id) == [bob.id])
    }

    @Test func notAMembersBusinessNorTheirOwn() {
        #expect(changes(bobOut(), canPlan: false).isEmpty)
        var mine = night(checkedIn: [me.id])
        mine.attendance[me.id] = false
        #expect(changes(mine).isEmpty)
    }

    @Test func dismissingItStaysDismissed() throws {
        let out = bobOut()
        let id = try #require(changes(out).first).id
        #expect(changes(out, dismissed: [id]).isEmpty)
    }

    @Test func leftoversAreExpectedForADishWithSomeoneStillHome() throws {
        #expect(try #require(changes(bobOut()).first).expectsLeftovers)
        #expect(try !#require(changes(bobOut(meal: nil, pick: .takeout)).first).expectsLeftovers)
        var alreadyCooked = bobOut()
        alreadyCooked.leftoversFrom = UUID()
        #expect(try !#require(changes(alreadyCooked).first).expectsLeftovers)
        var nobody = bobOut()
        nobody.attendance[me.id] = false
        #expect(try !#require(changes(nobody).first).expectsLeftovers)
    }

    @Test func someoneWhoEatsSeparatelyDoesntChangeTheLeftovers() throws {
        var baby = bob
        baby.eatsSeparately = true
        var out = bobOut()
        out.attendance[bob.id] = false
        let forBaby = DayOfCheckIn.changes(nights: [out], members: [me, baby], me: me.id, canPlan: true, today: F.day(8))
        #expect(try !#require(forBaby.first).expectsLeftovers, "they weren't eating it")

        out.attendance[me.id] = false
        out.attendance[baby.id] = true
        out.attendance[F.ben.id] = false
        out.checkedIn.insert(F.ben.id)
        let onlyBabyHome = DayOfCheckIn.changes(nights: [out], members: [me, F.ben, baby], me: me.id, canPlan: true, today: F.day(8))
        #expect(!onlyBabyHome.isEmpty)
        #expect(onlyBabyHome.allSatisfy { !$0.expectsLeftovers }, "and nobody's left to eat it")
    }

    @Test func aSwapIsOfferedWhenTheyWereTheReason() throws {
        let name = bob.firstName
        #expect(try #require(changes(bobOut(reason: PlanReason.favorite(name: name).text)).first).offersSwap)
        #expect(try #require(changes(bobOut(reason: PlanReason.request(name: name).text)).first).offersSwap)
        #expect(try !#require(changes(bobOut(reason: PlanReason.favorite(name: "Someone Else").text)).first).offersSwap)
        #expect(try !#require(changes(bobOut(reason: PlanReason.dueForATurn.text)).first).offersSwap)
        #expect(try !#require(changes(bobOut()).first).offersSwap)
    }
}

@Suite struct CheckInSettingsTests {
    @Test func itDefaultsToAfterSchool() {
        #expect(HouseholdSettings().checkInTime == "15:30")
    }

    @Test func itRoundTripsAndABadValueFallsBack() throws {
        var settings = HouseholdSettings()
        settings.checkInTime = "16:05"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(HouseholdSettings.self, from: data).checkInTime == "16:05")
        let bad = Data(#"{"check_in_time": "4pm"}"#.utf8)
        #expect(try JSONDecoder().decode(HouseholdSettings.self, from: bad).checkInTime == "15:30")
    }
}
