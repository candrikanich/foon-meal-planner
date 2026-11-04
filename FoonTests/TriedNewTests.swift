import Foundation
import Synchronization
import Testing
@testable import Foon

/// Picky-eater wins (docs/spec.md → Success metrics: shown to families): trying a new dish, celebrated gently.
struct TriedNewTests {
    private let nora = UUID()
    private let ben = UUID()

    @Test func decodesTheServersTries() throws {
        let json = Data("""
        [{"member_id": "\(nora.uuidString)", "dishes": 3}, {"member_id": "\(ben.uuidString)", "dishes": 1}]
        """.utf8)
        let decoded = try JSONDecoder().decode([TriedNewDishes].self, from: json)
        #expect(decoded == [TriedNewDishes(memberID: nora, dishes: 3), TriedNewDishes(memberID: ben, dishes: 1)])
    }

    @Test func aMembersMonthIsAboutTrying() {
        let tries = [TriedNewDishes(memberID: nora, dishes: 3), TriedNewDishes(memberID: ben, dishes: 1)]
        #expect(TriedNew.monthTitle(for: nora, in: tries) == "Tried 3 new dishes this month")
        #expect(TriedNew.monthTitle(for: ben, in: tries) == "Tried 1 new dish this month", "the catalog's plural")
    }

    @Test func nothingAtZero() {
        #expect(TriedNew.monthTitle(for: nora, in: []) == nil, "nobody's profile says they didn't try anything")
        #expect(TriedNew.monthTitle(for: nora, in: [TriedNewDishes(memberID: nora, dishes: 0)]) == nil)
        #expect(TriedNew.monthTitle(for: nora, in: [TriedNewDishes(memberID: ben, dishes: 2)]) == nil)
    }
}

/// The weekly recap's "Tried something new" line.
struct WeekRecapTriedNewTests {
    private typealias F = PlannerFixture
    private let ben = Member.fixture(firstName: "Ben")
    private let maya = Member.fixture(firstName: "Maya", ageGroup: .kid)
    private let gone = Member.fixture(firstName: "Lou", status: .removed)
    private let english = Locale(identifier: "en_US")

    private func recap(cooks: [UUID] = [], tried: [UUID], top: String? = nil) -> WeekRecap? {
        let facts = WeekRecapFacts(logged: 5, cooks: cooks, tried: tried,
                                   topDish: top.map { WeekRecapFacts.Dish(id: UUID(), name: $0) })
        return WeekRecap(weekStart: F.day(1), facts: facts, stats: FamilyStats(dinners: 6, dishes: 5),
                         members: [ben, maya, gone], settings: F.settings, calendar: F.calendar)
    }

    @Test func itComesRightAfterTheThanks() throws {
        let lines = try #require(recap(cooks: [ben.id], tried: [maya.id, ben.id], top: "Chili")).lines
        #expect(lines == [.stat(.dinners(6)), .thanks(["Ben"]), .triedNew(["Maya", "Ben"]), .topDish("Chili")])
    }

    @Test func itKeepsTheirOrderAndSkipsWhoeverLeft() throws {
        let lines = try #require(recap(tried: [ben.id, gone.id, UUID(), maya.id])).lines
        #expect(lines.contains(.triedNew(["Ben", "Maya"])), "kids included; removed, or not in the family: left out")
    }

    @Test func itsLeftOutWhenNobodyTriedAnything() throws {
        let lines = try #require(recap(tried: [gone.id])).lines
        #expect(!lines.contains { if case .triedNew = $0 { true } else { false } })
        #expect(try #require(recap(tried: [])).lines == [.stat(.dinners(6))])
    }

    @Test func itNamesPeopleWithoutCounting() {
        #expect(WeekRecap.Line.triedNew(["Maya"]).title(locale: english) == "Tried something new: Maya.")
        #expect(WeekRecap.Line.triedNew(["Maya", "Ben"]).title(locale: english)
            == "Tried something new: Maya and Ben.")
    }

    @Test func factsFromAServerWithoutTriedStillRead() throws {
        let json = Data(#"{"logged": 2, "cooks": [], "top_dish": null, "forgotten_favorite": null}"#.utf8)
        #expect(try JSONDecoder().decode(WeekRecapFacts.self, from: json) == WeekRecapFacts(logged: 2))
        let maya = UUID()
        let withTried = Data(#"{"logged": 2, "cooks": [], "tried": ["\#(maya.uuidString)"]}"#.utf8)
        #expect(try JSONDecoder().decode(WeekRecapFacts.self, from: withTried).tried == [maya])
    }
}

/// Loading a member's month for their profile: by the household's day, and quiet on failure.
@MainActor
struct TriedNewStoreTests {
    private func household(timeZone: String) -> Household {
        var settings = HouseholdSettings()
        settings.timeZone = timeZone
        return Household(id: Household.sample.id, name: "The Smiths", owner: .previewUser, settings: settings)
    }

    @Test func asksForTheMonthSoFarByTheHouseholdsDay() async {
        // 2026-12-01 03:00 UTC is still November 30 in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_796_094_000)
        let asked = Mutex<[(UUID, CalendarDay, CalendarDay)]>([])
        let home = household(timeZone: "America/Los_Angeles")
        let tries = [TriedNewDishes(memberID: Member.sampleFamily[4].id, dishes: 3)]
        var client = HouseholdClient.fake(myHousehold: { home }, members: { _ in Member.sampleFamily })
        client.triedNew = { id, from, to in
            asked.withLock { $0.append((id, from, to)) }
            return tries
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadTriedThisMonth(now: now)

        let call = asked.withLock { $0 }
        #expect(call.count == 1)
        #expect(call.first?.0 == home.id)
        #expect(call.first?.1 == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(call.first?.2 == CalendarDay(year: 2026, month: 11, day: 30))
        #expect(store.triedThisMonth == tries)
    }

    @Test func aFailedLoadStaysQuietAndKeepsWhatWasShown() async {
        let failing = Mutex(false)
        let tries = [TriedNewDishes(memberID: UUID(), dishes: 1)]
        var client = HouseholdClient.fake(myHousehold: { .sample }, members: { _ in Member.sampleFamily })
        client.triedNew = { _, _, _ in
            if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return tries
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadTriedThisMonth()
        failing.withLock { $0 = true }
        await store.loadTriedThisMonth()

        #expect(store.triedThisMonth == tries)
        #expect(store.errorMessage == nil, "the line never puts an error on a profile")
    }

    @Test func aNewHouseholdDoesNotShowTheOldOnesMonth() async {
        let current = Mutex(household(timeZone: "America/New_York"))
        let tries = [TriedNewDishes(memberID: UUID(), dishes: 2)]
        var client = HouseholdClient.fake(myHousehold: { current.withLock { $0 } },
                                          members: { _ in Member.sampleFamily })
        client.triedNew = { id, _, _ in
            if id == Household.sample.id { return tries }
            throw URLError(.notConnectedToInternet)
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadTriedThisMonth()
        #expect(store.triedThisMonth == tries)

        current.withLock {
            $0 = Household(id: UUID(), name: "Real family", owner: .previewUser, settings: $0.planningSettings)
        }
        await store.load()
        await store.loadTriedThisMonth()
        #expect(store.triedThisMonth == nil)
    }
}
