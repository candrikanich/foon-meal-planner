import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

private let sunday = CalendarDay(year: 2026, month: 11, day: 1)

private func stretch(_ first: Int, _ last: Int) -> AwayDates {
    AwayDates(from: sunday.adding(days: first), to: sunday.adding(days: last))
}

private func settings(away: [AwayDates]) -> HouseholdSettings {
    var settings = HouseholdSettings()
    settings.awayDates = away
    return settings
}

/// Vacation mode (#52): the dates themselves.
struct AwayDatesTests {
    private func decode(_ json: String) throws -> HouseholdSettings {
        try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
    }

    @Test func bothEndsCount() {
        let away = settings(away: [stretch(2, 3)])
        #expect(!away.isAway(on: sunday.adding(days: 1)))
        #expect(away.isAway(on: sunday.adding(days: 2)))
        #expect(away.isAway(on: sunday.adding(days: 3)))
        #expect(!away.isAway(on: sunday.adding(days: 4)))
    }

    @Test func settingsReadAwayDatesAndSkipAnythingBroken() throws {
        let read = try decode(#"""
        {"away_dates": [{"from": "2026-11-03", "to": "2026-11-04"}, {"from": "soon", "to": "2026-11-04"},
                        {"from": "2026-11-09", "to": "2026-11-08"}, "nonsense"]}
        """#)
        #expect(read.awayDates == [stretch(2, 3)])
        #expect(try decode(#"{"away_dates": "nope"}"#).awayDates.isEmpty)
        #expect(try decode("{}").awayDates.isEmpty)
    }

    /// Settings saves merge whatever they send. A stale copy of the dates mustn't undo another device's change, so only    /// add_away_dates and remove_away_dates write them.
    @Test func savingSettingsNeverSendsAwayDates() throws {
        let encoded = try JSONEncoder().encode(settings(away: [stretch(2, 3)]))
        let keys = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        #expect(!keys.contains("away_dates"))
        #expect(keys.contains("dinner_time"))
    }

    @Test func aStretchThatsOverIsNoLongerShown() {
        let away = settings(away: [stretch(0, 1), stretch(1, 3), stretch(5, 6)])
        #expect(away.awayDates(endingOnOrAfter: sunday.adding(days: 3)) == [stretch(1, 3), stretch(5, 6)],
                "its last night is still ahead tonight")
    }

    @Test func aStretchReadsPlainly() {
        #expect(stretch(2, 3).summary(today: sunday) == "Nov 3 to Nov 4")
        #expect(stretch(2, 2).summary(today: sunday) == "Nov 3")
    }

    /// "Dec 20 to Dec 20" reads fine for a year-long typo; the year gives it away.
    @Test func aStretchInAnotherYearSaysSo() {
        let typo = AwayDates(from: sunday, to: CalendarDay(year: 2027, month: 11, day: 1))
        #expect(typo.summary(today: sunday) == "Nov 1 to Nov 1, 2027")
        let later = AwayDates(from: CalendarDay(year: 2027, month: 1, day: 2), to: CalendarDay(year: 2027, month: 1, day: 3))
        #expect(later.summary(today: sunday) == "Jan 2, 2027 to Jan 3, 2027")
    }

    @Test func theConfirmationCountsTheNightsAndSaysWhatComesOff() {
        let night = { (offset: Int, name: String?, pick: QuickPick?) in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil,
                      mealID: name == nil ? nil : UUID(), mealName: name, quickPick: pick, locked: false, attendance: [:])
        }
        let week = [night(1, "Soup", nil), night(2, "Tacos", nil), night(3, nil, .takeout), night(4, nil, nil), night(5, "Chili", nil)]
        let message = stretch(2, 4).confirmation(today: sunday, week: week)
        #expect(message.contains("3 nights"))
        #expect(message.contains("Tacos"))
        #expect(message.contains("Takeout"))
        #expect(!message.contains("Soup"))
        #expect(!message.contains("Chili"))
        #expect(!message.contains("Tonight"))
        #expect(stretch(2, 2).confirmation(today: sunday, week: []).contains("1 night"))

        let fromTonight = stretch(0, 1).confirmation(today: sunday, week: [night(0, "Stew", nil), night(1, "Soup", nil)])
        #expect(fromTonight.contains("Tonight"), "tonight's dinner stays")
        #expect(!fromTonight.contains("Stew"), "so it isn't listed as coming off")
        #expect(fromTonight.contains("Soup"))
    }

    @Test func theLastNightFollowsTheFirst() {
        #expect(AwayDates.clampedLast(sunday, first: sunday.adding(days: 3)) == sunday.adding(days: 3), "never before it")
        #expect(AwayDates.clampedLast(sunday.adding(days: 500), first: sunday) == sunday.adding(days: 366),
                "or more than the year the server takes")
        #expect(AwayDates.clampedLast(sunday.adding(days: 5), first: sunday) == sunday.adding(days: 5))
    }

    /// The server goes by the household's day, so a planner travelling mustn't see a different one.
    @Test func todayIsTheHouseholdsDay() {
        var household = HouseholdSettings()
        let lateInLA = Date(timeIntervalSince1970: 1_793_500_000) // 2026-11-01 03:06 UTC
        household.timeZone = "America/Los_Angeles"
        #expect(household.today(now: lateInLA) == CalendarDay(year: 2026, month: 10, day: 31))
        household.timeZone = "Pacific/Auckland"
        #expect(household.today(now: lateInLA) == CalendarDay(year: 2026, month: 11, day: 1))
    }

    @Test func aWeekKnowsWhichDatesTouchIt() {
        let away = settings(away: [stretch(-2, 0), stretch(6, 7), stretch(9, 10)])
        #expect(away.awayDates(inWeekOf: sunday) == [stretch(-2, 0), stretch(6, 7)])
    }
}

/// Vacation mode (#52): what This Week and Build my week do with them.
@MainActor
struct AwayWeekTests {
    private func nights(planned: Set<Int> = []) -> [WeekNight] {
        (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil,
                      mealID: planned.contains(offset) ? UUID() : nil,
                      mealName: planned.contains(offset) ? "Meal \(offset)" : nil,
                      quickPick: nil, locked: false, attendance: [:])
        }
    }

    @Test func awayNightsAreShownButNotPlannable() {
        let layout = WeekLayout(nights: nights(planned: [0]), today: sunday, away: [stretch(2, 3)])
        #expect(layout.ahead.count == 7, "the card still shows")
        #expect(layout.plannable.map(\.date) == [0, 1, 4, 5, 6].map { sunday.adding(days: $0) })
        #expect(layout.emptyNights.map(\.date) == [1, 4, 5, 6].map { sunday.adding(days: $0) })
        #expect(layout.progress == .partlyPlanned)
    }

    /// Marking dates at 9pm keeps tonight's dinner, and a past night's dinner is history: neither reads as Away.
    @Test func aDinnerAlreadyOnTonightOrEarlierIsNotAway() {
        let layout = WeekLayout(nights: nights(planned: [0, 1, 2]), today: sunday.adding(days: 1), away: [stretch(0, 3)])
        let week = nights(planned: [0, 1, 2])
        let dates = [stretch(0, 3)], today = sunday.adding(days: 1)
        #expect(!week[0].readsAway(in: dates, today: today), "past, with a dinner")
        #expect(!week[1].readsAway(in: dates, today: today), "tonight, with a dinner")
        #expect(week[2].readsAway(in: dates, today: today), "a dinner on a later night is still away")
        #expect(nights()[0].readsAway(in: dates, today: today), "a past night with nothing on it is away")
        #expect(nights()[1].readsAway(in: dates, today: today), "and so is tonight with nothing on it")
        #expect(layout.plannable.map(\.date) == [1, 4, 5, 6].map { sunday.adding(days: $0) })
    }

    /// A week that was approved and then marked away still needs a way to update its list.
    @Test func anApprovedWeekWithAwayNightsStillOffersTheListUpdate() {
        let allAway = WeekLayout(nights: nights(), today: sunday, away: [stretch(0, 6)])
        #expect(allAway.offersApprove(approved: true))
        #expect(!allAway.offersApprove(approved: false), "nothing to approve")
        let partly = WeekLayout(nights: nights(planned: [5]), today: sunday, away: [stretch(0, 3)])
        #expect(partly.offersApprove(approved: false))
        #expect(!WeekLayout(nights: nights(), today: sunday).offersApprove(approved: true), "nothing to do with no away nights")
    }

    @Test func aWeekPlannedExceptItsAwayNightsIsPlanned() {
        let layout = WeekLayout(nights: nights(planned: [0, 1, 4, 5, 6]), today: sunday, away: [stretch(2, 3)])
        #expect(layout.progress == .planned)
    }

    @Test func aWeekAllAwayHasNothingToPlan() {
        let layout = WeekLayout(nights: nights(), today: sunday, away: [stretch(0, 6)])
        #expect(layout.plannable.isEmpty)
        #expect(layout.progress == .unplanned)
    }

    @Test func aMealLeftOnAnAwayNightStaysOffTheList() {
        // An older app can still swap a dinner onto an away night; the list is built from plannable nights.
        let layout = WeekLayout(nights: nights(planned: [2, 4]), today: sunday, away: [stretch(2, 3)])
        #expect(layout.plannable.filter(\.isPlanned).map(\.date) == [sunday.adding(days: 4)])
    }

    @Test func buildMyWeekPlansNothingOnAnAwayNightWhoeverIsHome() {
        let me = UUID()
        let week = (0..<7).map { offset in
            WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: nil, mealID: nil,
                      mealName: nil, quickPick: nil, locked: false, attendance: [me: true])
        }
        let meals = (0..<10).map { LibraryMeal.fixture(name: "Dish \($0)") }
        var away = settings(away: [stretch(2, 3)])
        away.leftoverNights = 0
        let context = PlanningContext(
            meals: meals, history: [], settings: away, members: [.fixture(id: me)],
            requests: [DatedRequest(mealID: meals[0].id, date: sunday.adding(days: 2), requesterID: me)],
            wanted: [WantedRequest(mealID: meals[1].id, requesterID: me, wanters: [me])],
            traditions: [Tradition(weekday: sunday.adding(days: 3).isoWeekday, pick: .meal(meals[2].id), name: "Tacos")]
        )
        let inputs = context.inputs(for: Week(planID: UUID(), start: sunday, nights: week), today: sunday)
        let draft = BuildMyWeek.draft(inputs, seed: 3)
        #expect(draft[2].pick == nil, "not even a dated request")
        #expect(draft[3].pick == nil, "or a tradition")
        #expect(draft.indices.filter { ![2, 3].contains($0) }.allSatisfy { draft[$0].pick != nil })
        #expect(BuildMyWeek.shuffle(night: week[2].id, inputs: inputs, seed: 1) == nil)
    }

    @Test func anAwayNightsCardSaysSoAndNothingElse() {
        let member = Member.fixture(firstName: "Ann")
        let night = WeekNight(id: UUID(), date: sunday, effort: .rushed, dinnerTime: nil, mealID: UUID(), mealName: "Tacos",
                              quickPick: nil, locked: true, attendance: [member.id: false])
        let card = WeekStore.card(for: night, members: [member], isAway: true)
        #expect(card.slot == .away)
        #expect(card.attendance.isEmpty)
        #expect(!card.isLocked)
        let summary = DayCardText.accessibilitySummary(card, today: sunday)
        #expect(summary.contains("Away"))
        #expect(!summary.contains("Rushed"), "there's no effort to speak of")
        #expect(!summary.contains("Tacos"))
    }

    @Test func theStoreLaysOutTheWeekAroundAwayDates() async {
        let week = Week(planID: UUID(), start: sunday, nights: nights())
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in week }), today: { sunday })
        await store.load(settings: settings(away: [stretch(0, 6)]))
        #expect(store.layout?.plannable.isEmpty == true)
        await store.load(settings: HouseholdSettings())
        #expect(store.layout?.plannable.count == 7, "ending the dates opens the nights again")
    }

    @Test(arguments: [
        (0, [stretch(0, 6)], true),
        (3, [stretch(3, 6)], true),
        (3, [stretch(4, 6)], false),
        (0, [stretch(3, 6)], false),
        (0, [AwayDates](), false)
    ])
    func awayForTheRestOfTheWeekCountsFromToday(today: Int, away: [AwayDates], expected: Bool) async {
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in nil }),
                              today: { sunday.adding(days: today) })
        await store.load(settings: settings(away: away))
        #expect(store.isAwayForTheRestOfTheWeek == expected)
    }

    /// The server clears nights by the household's day; This Week has to agree with it for a planner travelling.
    @Test func theStoreGoesByTheHouseholdsDay() async {
        let lateInLA = Date(timeIntervalSince1970: 1_793_500_000) // 2026-11-01 03:06 UTC
        let store = WeekStore(householdID: Household.sample.id, client: .fake(week: { _, _ in nil }), now: { lateInLA })
        var household = HouseholdSettings()
        household.timeZone = "America/Los_Angeles"
        await store.load(settings: household)
        #expect(store.todayDay == CalendarDay(year: 2026, month: 10, day: 31))
        household.timeZone = "Pacific/Auckland"
        await store.load(settings: household)
        #expect(store.todayDay == CalendarDay(year: 2026, month: 11, day: 1))
    }

    @Test func planItNeverOffersAnAwayNight() {
        let tacos = UUID()
        let layout = WeekLayout(nights: nights(), today: sunday, away: [stretch(2, 3)])
        #expect(PlanIt.choices(in: layout, for: tacos).map(\.date) == [0, 1, 4, 5, 6].map { sunday.adding(days: $0) })
        #expect(PlanIt.choices(in: layout, for: tacos, includingPlanned: true).count == 5,
                "not from Ideas either")
        let allAway = WeekLayout(nights: nights(), today: sunday, away: [stretch(0, 6)])
        #expect(PlanIt.state(layout: allAway, mealID: tacos, isLoading: false, hasLoaded: true, loadError: nil)
                == .noNightsLeft)
    }

    @Test func planItDoesntSayStartTheWeekWhenTheFamilyIsAway() {
        #expect(PlanIt.state(layout: nil, mealID: UUID(), isLoading: false, hasLoaded: true, loadError: nil,
                             awayForTheRest: true) == .away)
        #expect(PlanIt.state(layout: nil, mealID: UUID(), isLoading: false, hasLoaded: true, loadError: nil) == .noWeek)
    }
}

/// Saving, switching, and the away dates in the household store (#52).
@MainActor
struct HouseholdAwayAndTemplateTests {
    private let me = UUID()
    private let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: nil)

    /// The server's list wins: it holds what other planners added since this device last loaded.
    @Test func savingAwayDatesShowsTheServersList() async {
        let household = household
        let fromAnotherPlanner = stretch(10, 11)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            addAwayDates: { _, new in [new, fromAnotherPlanner] },
            removeAwayDates: { _, removed in
                #expect(removed == stretch(2, 3))
                return [fromAnotherPlanner]
            }
        ))
        await store.load()
        #expect(await store.addAwayDates(stretch(2, 3)))
        #expect(store.household?.planningSettings.awayDates == [stretch(2, 3), fromAnotherPlanner])

        #expect(await store.removeAwayDates(stretch(2, 3)))
        #expect(store.household?.planningSettings.awayDates == [fromAnotherPlanner])
    }

    @Test func aHouseholdReloadPicksUpAnotherPlannersDates() async {
        let dates = Mutex<[AwayDates]>([])
        let id = household.id
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: {
            var settings = HouseholdSettings()
            settings.awayDates = dates.withLock { $0 }
            return Household(id: id, name: "The Smiths", emoji: nil, owner: nil, settings: settings)
        }))
        await store.load()
        #expect(store.household?.planningSettings.awayDates == [])
        dates.withLock { $0 = [stretch(2, 3)] }
        await store.load()
        #expect(store.household?.planningSettings.awayDates == [stretch(2, 3)])
    }

    @Test func refusedDatesSayWhatsWrongNotCheckYourConnection() async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            addAwayDates: { _, _ in throw PostgrestError(code: "22023", message: "refused") }
        ))
        await store.load()
        #expect(await !store.addAwayDates(stretch(2, 3)))
        #expect(store.errorMessage?.contains("connection") == false)
        #expect(store.errorMessage?.contains("year") == true)
    }

    @Test func aRefusedSaveKeepsTheDatesAndSaysSo() async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            addAwayDates: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        #expect(await !store.addAwayDates(stretch(2, 3)))
        #expect(store.household?.planningSettings.awayDates == [])
        #expect(store.errorMessage?.contains("connection") == true)
    }

    @Test func aSettingsSaveAfterwardKeepsTheDatesOnThisDevice() async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }, addAwayDates: { _, new in [new] }))
        await store.load()
        #expect(await store.addAwayDates(stretch(2, 3)))
        var changed = store.household?.planningSettings ?? HouseholdSettings()
        changed.takeoutNights = 3
        #expect(await store.updateSettings(changed))
        #expect(store.household?.planningSettings.awayDates == [stretch(2, 3)])
    }

    @Test func savingATemplateAddsItOrReplacesTheOneWithThatName() async {
        let household = household
        let first = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [:])
        let replaced = AttendanceTemplate(id: first.id, name: "SUMMER", schedules: [:])
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            attendanceTemplates: { _ in [AttendanceTemplate(id: UUID(), name: "Baseball", schedules: [:])] },
            saveAttendanceTemplate: { _, name in name == "Summer" ? first : replaced }
        ))
        await store.load()
        await store.loadTemplates()
        #expect(await store.saveTemplate(named: "  Summer "))
        #expect(store.attendanceTemplates.map(\.name) == ["Baseball", "Summer"], "sorted by name")
        #expect(await store.saveTemplate(named: "SUMMER"))
        #expect(store.attendanceTemplates.map(\.name) == ["Baseball", "SUMMER"])
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: 41)])
    func aTemplateNameMustFit(_ name: String) async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }))
        await store.load()
        #expect(await !store.saveTemplate(named: name))
        #expect(store.errorMessage != nil)
    }

    @Test func switchingRefreshesEveryonesSchedule() async {
        let household = household
        let owenID = UUID()
        let template = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [owenID: AttendanceDefaults(usuallyAway: [1])])
        let applied = Mutex(false)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            members: { _ in
                var owen = Member.fixture(id: owenID, firstName: "Owen")
                owen.attendanceDefaults = AttendanceDefaults(usuallyAway: applied.withLock { $0 } ? [1] : [2])
                return [owen]
            },
            applyAttendanceTemplate: { id in
                #expect(id == template.id)
                applied.withLock { $0 = true }
            }
        ))
        await store.load()
        #expect(!template.isInUse(by: store.members))
        #expect(await store.applyTemplate(template))
        #expect(store.members.first?.usuallyAway == [1])
        #expect(template.isInUse(by: store.members))
    }

    @Test func deletingATemplateTakesItOffTheList() async {
        let household = household
        let template = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [:])
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household }, attendanceTemplates: { _ in [template] }
        ))
        await store.load()
        await store.loadTemplates()
        #expect(await store.deleteTemplate(template))
        #expect(store.attendanceTemplates.isEmpty)
    }

    @Test func aFailedTemplateLoadSaysSo() async {
        let household = household
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household }, attendanceTemplates: { _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        await store.loadTemplates()
        #expect(store.errorMessage != nil)
    }
}

struct AttendanceTemplateTests {
    private let owen = Member.fixture(firstName: "Owen")
    private let nora = Member.fixture(firstName: "Nora")

    @Test func decodesTheServersRowAndSkipsBadKeys() throws {
        let id = UUID()
        let template = try JSONDecoder().decode(AttendanceTemplate.self, from: Data("""
        {"id": "\(id.uuidString.lowercased())", "household_id": "\(UUID().uuidString)", "name": "Summer",
         "schedules": {"\(owen.id.uuidString.lowercased())": {"usually_away": [1, 2]}, "\(nora.id.uuidString)": {},
                       "not-a-member": {"usually_away": [3]}}, "created_at": "2026-10-30T12:00:00Z"}
        """.utf8))
        #expect(template.id == id)
        #expect(template.name == "Summer")
        #expect(template.schedules == [owen.id: AttendanceDefaults(usuallyAway: [1, 2]), nora.id: AttendanceDefaults()])
    }

    @Test func aSameNamedScheduleIsFoundWhateverTheCapitals() {
        let summer = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [:])
        #expect(AttendanceTemplate.existing(named: "  SUMMER ", in: [summer]) == summer)
        #expect(AttendanceTemplate.existing(named: "Winter", in: [summer]) == nil)
    }

    @Test func inUseMeansSwitchingWouldChangeNothing() {
        var scheduled = owen
        scheduled.attendanceDefaults = AttendanceDefaults(usuallyAway: [1])
        let template = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [owen.id: AttendanceDefaults(usuallyAway: [1])])
        #expect(template.isInUse(by: [scheduled, nora]), "someone added since keeps their own either way")
        #expect(!template.isInUse(by: [owen]), "Owen's nights differ")
        #expect(!template.isInUse(by: [nora]), "nobody in it is still here")
        var removed = scheduled
        removed.status = .removed
        #expect(!template.isInUse(by: [removed]))
    }

    @Test func theSummaryNamesWhosOutInFamilyOrder() {
        let template = AttendanceTemplate(id: UUID(), name: "School year", schedules: [
            owen.id: AttendanceDefaults(usuallyAway: [2, 1]), nora.id: AttendanceDefaults()
        ])
        let monday = WeekMath.weekdays[0].shortName(), tuesday = WeekMath.weekdays[1].shortName()
        #expect(template.summary(members: [nora, owen]) == "Owen out \(monday), \(tuesday)")
        let everyone = AttendanceTemplate(id: UUID(), name: "Summer", schedules: [nora.id: AttendanceDefaults()])
        #expect(everyone.summary(members: [nora, owen]) == "Everyone home every night")
    }
}
