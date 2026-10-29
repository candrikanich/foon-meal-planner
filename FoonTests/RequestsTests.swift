import Foundation
import Synchronization
import Testing
@testable import Foon

struct RequestBoardTests {
    private let monday = CalendarDay(year: 2026, month: 11, day: 2)
    private let nora = UUID(), owen = UUID(), ann = UUID()
    private let tacos = UUID()

    @Test func sortsIntoThisWeekSomedayAndNewFinds() {
        let today = monday.adding(days: 1)
        let dated = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday.adding(days: 4))
        let planned = DinnerRequest(requestedByMemberID: owen, mealID: tacos, status: .planned, plannedNightID: UUID(),
                                    plannedDate: monday)
        let someday = DinnerRequest(requestedByMemberID: owen, title: "Crab legs", plusOnes: [ann])
        let missed = DinnerRequest(requestedByMemberID: nora, title: "Pie", targetDate: monday)
        let link = DinnerRequest(requestedByMemberID: ann, title: "Gnocchi", link: URL(string: "https://r.example/g"))
        let special = DinnerRequest(requestedByMemberID: owen, title: "Steak", targetDate: monday.adding(days: 3),
                                    status: .special)
        let plannedThursday = DinnerRequest(requestedByMemberID: nora, title: "Soup", status: .planned,
                                            plannedNightID: UUID(), plannedDate: monday.adding(days: 3))
        let datedWednesday = DinnerRequest(requestedByMemberID: owen, mealID: tacos, targetDate: monday.adding(days: 2))
        let nextWeek = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday.adding(days: 9))
        let plannedNextWeek = DinnerRequest(requestedByMemberID: nora, mealID: tacos, status: .planned,
                                            plannedNightID: UUID(), plannedDate: monday.adding(days: 8))
        let lastWeek = DinnerRequest(requestedByMemberID: nora, mealID: tacos, status: .planned, plannedNightID: UUID(),
                                     plannedDate: monday.adding(days: -3))
        let sections = RequestBoard.sections([dated, planned, someday, missed, link, special, plannedThursday,
                                              datedWednesday, nextWeek, plannedNextWeek, lastWeek],
                                             weekStart: monday, today: today)
        #expect(sections.thisWeek.map(\.id) == [planned.id, datedWednesday.id, plannedThursday.id, dated.id],
                "by the night they're on, planned or asked for; planned this week stays even once its night passed")
        #expect(sections.later.map(\.id) == [plannedNextWeek.id, nextWeek.id])
        #expect(!sections.someday.contains { $0.id == lastWeek.id } && !sections.thisWeek.contains { $0.id == lastWeek.id },
                "tried in an earlier week is history, off the board")
        #expect(Set(sections.someday.map(\.id)) == [someday.id, missed.id, special.id],
                "an unplanned night that went by moves to Someday")
        #expect(sections.newFinds.map(\.id) == [link.id])
        #expect(sections.someday.first?.id == someday.id, "most me-toos first")
    }

    @Test func whatEachOneSays() {
        let today = monday.adding(days: 2)
        #expect(RequestBoard.shown(DinnerRequest(requestedByMemberID: nora, title: "x"), today: today) == .waiting)
        #expect(RequestBoard.shown(DinnerRequest(requestedByMemberID: nora, mealID: tacos, status: .planned,
                                                 plannedNightID: UUID(), plannedDate: monday.adding(days: 4)),
                                   today: today) == .planned(monday.adding(days: 4)))
        #expect(RequestBoard.shown(DinnerRequest(requestedByMemberID: nora, mealID: tacos, status: .planned,
                                                 plannedNightID: UUID(), plannedDate: monday),
                                   today: today) == .tried)
        #expect(RequestBoard.shown(DinnerRequest(requestedByMemberID: nora, title: "x", status: .special),
                                   today: today) == .specialOccasion)
    }

    @Test func buildMyWeekLandsOpenDatedDishesThisWeek() {
        let today = monday.adding(days: 1)
        let friday = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday.adding(days: 4))
        let past = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday)
        let nextWeek = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday.adding(days: 9))
        let noDish = DinnerRequest(requestedByMemberID: nora, title: "Crab legs", targetDate: monday.adding(days: 3))
        let done = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: monday.adding(days: 5),
                                 status: .planned, plannedNightID: UUID(), plannedDate: monday.adding(days: 5))
        #expect(RequestBoard.dated([friday, past, nextWeek, noDish, done], weekStart: monday, today: today)
            == [DatedRequest(mealID: tacos, date: monday.adding(days: 4), requesterID: nora)])
        #expect(RequestBoard.waitingCount([friday, past, noDish, done]) == 3)
    }

    @Test func decodesTheirRowsWithMeTooAndThePlannedNight() throws {
        let json = #"""
        [{"id":"6B1A2B49-8F7C-4E52-9C1F-3A1D2E4F5A61","requested_by_member_id":"0B2C7E7A-6D18-4A51-8E7C-2F6A9B1C3D4E",
          "meal_id":null,"title":"Crab legs","link":"https://r.example/crab","note":null,"target_date":null,
          "status":"planned","planned_night_id":"9E1F2A3B-4C5D-4E6F-8A7B-1C2D3E4F5A6B","created_at":"2026-11-01T12:00:00Z",
          "request_plus_ones":[{"member_id":"1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"}],"plan_nights":{"date":"2026-11-06"}}]
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try #require(try decoder.decode([DinnerRequest].self, from: Data(json.utf8)).first)
        #expect(request.title == "Crab legs")
        #expect(request.link?.host() == "r.example")
        #expect(request.plannedDate == CalendarDay(year: 2026, month: 11, day: 6))
        #expect(request.plusOnes.count == 1)
    }
}

@MainActor
struct IdeasStoreTests {
    @Test func sendingAnIdeaReloads() async {
        let made = Mutex<[NewRequest]>([])
        let loads = Mutex(0)
        let store = IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in loads.withLock { $0 += 1 }; return [] },
            make: { _, request in made.withLock { $0.append(request) }; return UUID() },
            toggleMeToo: { _, _ in true }, update: { _, _ in }
        ))
        let request = NewRequest(from: UUID(), title: "Crab legs")
        #expect(await store.make(request))
        #expect(made.withLock { $0 } == [request])
        #expect(loads.withLock { $0 } == 1)
    }

    @Test(arguments: [
        (IdeasStore.Action.meToo, "22023", "already your idea"),
        (.meToo, "42501", "for yourself"),
        (.make, "42501", "for yourself"),
        (.make, "22023", "already passed"),
        (.update, "42501", "Only planners"),
        (.update, "22023", "Pick a night")
    ])
    func eachRefusalSaysWhatWasTried(action: IdeasStore.Action, code: String, says: String) {
        #expect(IdeasStore.message(for: action, code: code).contains(says))
    }

    @Test func aDoubleTapSendsOnce() async {
        let sent = Mutex(0)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let store = IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in [] },
            make: { _, _ in
                sent.withLock { $0 += 1 }
                for await _ in gate { break }
                return UUID()
            },
            toggleMeToo: { _, _ in true }, update: { _, _ in }
        ))
        let first = Task { await store.make(NewRequest(from: UUID(), title: "Pie")) }
        while !store.isSending { await Task.yield() }
        #expect(!(await store.make(NewRequest(from: UUID(), title: "Pie"))))
        open.yield()
        open.finish()
        _ = await first.value
        #expect(sent.withLock { $0 } == 1)
    }

    @Test func aRefusedPlanSaysWhy() async {
        let store = IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in [] }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true },
            update: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        #expect(!(await store.update(UUID(), RequestUpdate(status: .special))))
        #expect(store.errorMessage != nil)
        #expect(store.saving.isEmpty)
    }
}

struct RequestLandingTests {
    private let monday = CalendarDay(year: 2026, month: 11, day: 2)
    private let tacos = UUID(), chili = UUID(), nora = UUID()

    private func night(_ offset: Int, meal: UUID?) -> WeekNight {
        WeekNight(id: UUID(), date: monday.adding(days: offset), effort: .normal, dinnerTime: nil, mealID: meal,
                  mealName: nil, quickPick: nil, locked: false, attendance: [:])
    }

    @Test func aDatedRequestLandsWhenItsNightHasTheDish() {
        let friday = night(4, meal: tacos), thursday = night(3, meal: chili)
        let landed = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: friday.date)
        let swapped = DinnerRequest(requestedByMemberID: nora, mealID: tacos, targetDate: thursday.date)
        let someday = DinnerRequest(requestedByMemberID: nora, mealID: tacos)
        let result = RequestBoard.landed([landed, swapped, someday], nights: [thursday, friday])
        #expect(result.map(\.requestID) == [landed.id])
        #expect(result.map(\.nightID) == [friday.id])
    }

    @Test func requestsInWords() {
        let request = DinnerRequest(requestedByMemberID: nora, title: "Crab legs", targetDate: monday.adding(days: 4))
        #expect(RequestText.from("Nora", request: request) == "From Nora, for Friday")
        #expect(RequestText.from("Nora", request: DinnerRequest(requestedByMemberID: nora, title: "x")) == "From Nora")
        #expect(RequestText.status(.specialOccasion) == "Special occasion")
        #expect(RequestText.status(.planned(monday.adding(days: 4))) == "Planned for Friday")
    }
}

struct RequestRulesTests {
    private let ann = Member.fixture(firstName: "Ann", guardian: true, userID: UUID())
    private let ben = Member.fixture(firstName: "Ben", userID: UUID())
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)

    @Test func archivingFollowsTheServersRule() {
        let mine = DinnerRequest(requestedByMemberID: ben.id, title: "x", enteredByMemberID: ben.id)
        let forNora = DinnerRequest(requestedByMemberID: nora.id, title: "x", enteredByMemberID: ben.id)
        let annsForNora = DinnerRequest(requestedByMemberID: nora.id, title: "x", enteredByMemberID: ann.id)
        var claimedNora = nora
        claimedNora.userID = UUID()
        #expect(RequestBoard.canArchive(mine, me: ben, members: [ann, ben, nora]))
        #expect(RequestBoard.canArchive(forNora, me: ben, members: [ann, ben, nora]), "entered on Ben's phone")
        #expect(!RequestBoard.canArchive(annsForNora, me: ben, members: [ann, ben, nora]))
        #expect(!RequestBoard.canArchive(forNora, me: ben, members: [ann, ben, claimedNora]),
                "once Nora has her own account, it's hers")
    }

    @Test func buildingARequestFromTheSheet() {
        let from = UUID()
        #expect(NewRequest.build(kind: .name, from: from, mealID: nil, title: "  Crab legs ", link: "", note: " ",
                                 date: nil) == NewRequest(from: from, title: "Crab legs"))
        #expect(NewRequest.build(kind: .name, from: from, mealID: nil, title: "  ", link: "", note: "", date: nil) == nil)
        #expect(NewRequest.build(kind: .link, from: from, mealID: nil, title: "", link: "recipes.example/x", note: "",
                                 date: nil)?.link == "https://recipes.example/x")
        #expect(NewRequest.build(kind: .link, from: from, mealID: nil, title: "", link: "not a link", note: "",
                                 date: nil) == nil)
        #expect(NewRequest.build(kind: .library, from: from, mealID: nil, title: "", link: "", note: "", date: nil) == nil)
        #expect(NewRequest.build(kind: .name, from: from, mealID: nil, title: String(repeating: "x", count: 81), link: "",
                                 note: "", date: nil) == nil, "over the server's limit")
    }

    @Test func aSwapTakesTheDishAwayAndTheIdeaGoesBackToOpen() {
        let tacos = UUID()
        let night = WeekNight(id: UUID(), date: CalendarDay(year: 2026, month: 11, day: 6), effort: .normal,
                              dinnerTime: nil, mealID: UUID(), mealName: "Chili", quickPick: nil, locked: false,
                              attendance: [:])
        let planned = DinnerRequest(requestedByMemberID: UUID(), mealID: tacos, status: .planned, plannedNightID: night.id,
                                    plannedDate: night.date)
        #expect(RequestBoard.unlanded([planned], nights: [night]) == [planned.id])
    }
}

@MainActor
struct MarkLandedTests {
    @Test func marksWhatBuildMyWeekLanded() async {
        let monday = CalendarDay(year: 2026, month: 11, day: 2)
        let tacos = UUID()
        let friday = WeekNight(id: UUID(), date: monday.adding(days: 4), effort: .normal, dinnerTime: nil, mealID: tacos,
                               mealName: "Tacos", quickPick: nil, locked: false, attendance: [:])
        let request = DinnerRequest(requestedByMemberID: UUID(), mealID: tacos, targetDate: friday.date)
        let updates = Mutex<[RequestUpdate]>([])
        let store = IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in [request] }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true },
            update: { _, update in updates.withLock { $0.append(update) } }
        ))
        await store.load()
        await store.sync(with: Week(planID: UUID(), start: monday, approvedAt: nil, nights: [friday]))
        #expect(updates.withLock { $0 } == [RequestUpdate(status: .planned, nightID: friday.id)])
    }
}
