import Foundation
import Synchronization
import Testing
@testable import Foon

/// The planner engagement view (docs/spec.md → Keeping kids engaged without nagging): what each person did, in family
/// order, worded as thanks; never a ranking, a total, or a streak.
struct EngagementTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// Wednesday, November 4, 2026.
    private let today = CalendarDay(year: 2026, month: 11, day: 4)
    private let ann = Member.fixture(firstName: "Ann", guardian: true, role: .planner)
    private let ben = Member.fixture(firstName: "Ben", guardian: true)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)

    private func day(_ day: Int, month: Int = 11) -> CalendarDay { CalendarDay(year: 2026, month: month, day: day) }

    private func counts(_ member: Member, ideas: Int = 0, meToos: Int = 0, rated: Int = 0, checkIns: Int = 0,
                        claimed: Int = 0, cooked: [CalendarDay] = [], lastIdeaOn: CalendarDay? = nil,
                        joinedOn: CalendarDay? = CalendarDay(year: 2026, month: 9, day: 1)) -> EngagementCounts {
        EngagementCounts(memberID: member.id, ideas: ideas, meToos: meToos, rated: rated, checkIns: checkIns,
                         claimed: claimed, cooked: cooked, lastIdeaOn: lastIdeaOn, joinedOn: joinedOn)
    }

    private func rows(_ members: [Member], thisWeek: [EngagementCounts] = [], lately: [EngagementCounts])
        -> [Engagement.Row] {
        Engagement.rows(members: members, thisWeek: EngagementFacts(members: thisWeek),
                        lately: EngagementFacts(members: lately), today: today, calendar: Self.calendar)
    }

    // MARK: Decoding

    @Test func decodesTheServersCounts() throws {
        let json = Data("""
        {"members": [{"member_id": "\(owen.id.uuidString)", "ideas": 2, "me_toos": 1, "rated": 5, "check_ins": 3,
          "claimed": 1, "cooked": ["2026-11-03"], "last_idea_on": "2026-11-02", "joined_on": "2026-09-01"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(EngagementFacts.self, from: json)
        #expect(decoded.members == [counts(owen, ideas: 2, meToos: 1, rated: 5, checkIns: 3, claimed: 1,
                                           cooked: [day(3)], lastIdeaOn: day(2), joinedOn: day(1, month: 9))])
    }

    @Test func aServerThatSaysLessStillReads() throws {
        let json = Data(#"{"members": [{"member_id": "\#(owen.id.uuidString)", "ideas": 1}]}"#.utf8)
        let decoded = try JSONDecoder().decode(EngagementFacts.self, from: json)
        #expect(decoded.members == [counts(owen, ideas: 1, joinedOn: nil)])
        #expect(try JSONDecoder().decode(EngagementFacts.self, from: Data("{}".utf8)) == EngagementFacts())
    }

    // MARK: Windows

    @Test func thisWeekIsThePlanWeekAndLatelyIsFourWeeksEndingToday() {
        let sunday = Engagement.windows(today: today, weekStart: 7, calendar: Self.calendar)
        #expect(sunday.thisWeek == Engagement.Window(from: day(1), to: day(7)))
        #expect(sunday.lately == Engagement.Window(from: day(8, month: 10), to: today))
        let monday = Engagement.windows(today: today, weekStart: 1, calendar: Self.calendar)
        #expect(monday.thisWeek == Engagement.Window(from: day(2), to: day(8)))
    }

    // MARK: Wording

    @Test func oneWarmLineOfWhatTheyDid() {
        let line = Engagement.summary(counts(owen, ideas: 2, meToos: 1, rated: 5, checkIns: 1, claimed: 2,
                                             cooked: [day(3)]),
                                      namingDays: true, calendar: Self.calendar)
        #expect(line == "sent 2 ideas · said me too to 1 idea · rated 5 dinners · answered 1 check-in · "
            + "claimed 2 nights · cooked Tuesday")
    }

    @Test func pluralsComeFromTheCatalog() {
        let line = Engagement.summary(counts(owen, ideas: 1, meToos: 2, rated: 1, checkIns: 2, claimed: 1),
                                      namingDays: false, calendar: Self.calendar)
        #expect(line == "sent 1 idea · said me too to 2 ideas · rated 1 dinner · answered 2 check-ins · "
            + "claimed 1 night")
    }

    @Test func cookingIsADayThisWeekAndACountLately() {
        let once = counts(owen, cooked: [day(3)])
        let twice = counts(owen, cooked: [day(1), day(3)])
        #expect(Engagement.summary(once, namingDays: true, calendar: Self.calendar) == "cooked Tuesday")
        #expect(Engagement.summary(twice, namingDays: true, calendar: Self.calendar) == "cooked 2 dinners")
        #expect(Engagement.summary(once, namingDays: false, calendar: Self.calendar) == "cooked 1 dinner")
    }

    @Test func zerosAreLeftOut() {
        #expect(Engagement.summary(counts(owen, rated: 3), namingDays: false, calendar: Self.calendar)
            == "rated 3 dinners")
        #expect(Engagement.summary(counts(owen), namingDays: false, calendar: Self.calendar) == nil)
    }

    // MARK: Rows

    @Test func familyOrderNeverSortedByCounts() {
        let shown = rows([ann, ben, owen, nora], lately: [
            counts(nora, rated: 9, lastIdeaOn: day(1)), counts(ann, rated: 1, lastIdeaOn: day(1)),
            counts(owen, rated: 4, lastIdeaOn: day(1)), counts(ben, rated: 2, lastIdeaOn: day(1))
        ])
        #expect(shown.map(\.member.firstName) == ["Ann", "Ben", "Owen", "Nora"])
    }

    @Test func eachRowSaysThisWeekAndTheLastFourWeeks() throws {
        let shown = rows([owen], thisWeek: [counts(owen, ideas: 1, cooked: [day(3)], lastIdeaOn: day(2))],
                         lately: [counts(owen, ideas: 3, rated: 6, cooked: [day(3)], lastIdeaOn: day(2))])
        let row = try #require(shown.first)
        #expect(row.thisWeek == "This week: sent 1 idea · cooked Tuesday")
        #expect(row.lately == "Last 4 weeks: sent 3 ideas · rated 6 dinners · cooked 1 dinner")
        #expect(row.note == nil)
    }

    @Test func theFourWeeksLineIsLeftOutWhenItsTheSameAsThisWeek() throws {
        let same = counts(owen, ideas: 1, cooked: [day(3)], lastIdeaOn: day(2))
        let row = try #require(rows([owen], thisWeek: [same], lately: [same]).first)
        #expect(row.thisWeek == "This week: sent 1 idea · cooked Tuesday")
        #expect(row.lately == nil)
    }

    @Test func nothingLatelyIsAQuietNudgeForTheParent() throws {
        let row = try #require(rows([owen], lately: [counts(owen, lastIdeaOn: day(1, month: 9))]).first)
        #expect(row.thisWeek == nil)
        #expect(row.lately == nil)
        #expect(row.note == "No ideas from Owen lately. Maybe ask what sounds good?")
    }

    @Test func aClaimLaterThisWeekIsntNothingLately() throws {
        // Monday's claim on Thursday is this week's, but after today, so the 4 weeks ending today don't have it.
        let row = try #require(rows([owen], thisWeek: [counts(owen, claimed: 1)], lately: [counts(owen)]).first)
        #expect(row.thisWeek == "This week: claimed 1 night")
        #expect(row.note == "No ideas from Owen in 3 weeks.", "never \"nothing lately\" beside something this week")
    }

    @Test func busyButNoIdeasInThreeWeeks() throws {
        let quiet = try #require(rows([owen], lately: [counts(owen, rated: 4, lastIdeaOn: day(14, month: 10))]).first)
        #expect(quiet.note == "No ideas from Owen in 3 weeks.")
        let never = try #require(rows([owen], lately: [counts(owen, rated: 4)]).first)
        #expect(never.note == "No ideas from Owen in 3 weeks.")
        let recent = try #require(rows([owen], lately: [counts(owen, rated: 4, lastIdeaOn: day(15, month: 10))]).first)
        #expect(recent.note == nil, "an idea 21 days ago, today included, is within the 3 weeks")
    }

    @Test func noNoteForPlannersAwayEatsSeparatelyOrNewcomers() {
        var away = owen
        away.status = .away
        var baby = nora
        baby.eatsSeparately = true
        let shown = rows([ann, away, baby], lately: [counts(ann), counts(away), counts(baby)])
        #expect(shown.isEmpty, "planners plan; nobody's nudged while away or for not rating as a baby")

        let newcomer = rows([owen], lately: [counts(owen, rated: 2, joinedOn: day(20, month: 10))])
        #expect(newcomer.first?.note == nil, "they haven't been here 3 weeks yet")
        #expect(rows([owen], lately: [counts(owen, joinedOn: day(20, month: 10))]).isEmpty)
    }

    @Test func plannersStillGetTheirThanks() throws {
        let row = try #require(rows([ann], lately: [counts(ann, cooked: [day(2)])]).first)
        #expect(row.lately == "Last 4 weeks: cooked 1 dinner")
        #expect(row.note == nil)
    }

    @Test func removedMembersAndStrangersArentShown() {
        var gone = ben
        gone.status = .removed
        let shown = rows([gone, owen], lately: [
            counts(gone, rated: 3), counts(nora, rated: 3), counts(owen, rated: 1, lastIdeaOn: day(1))
        ])
        #expect(shown.map(\.member.firstName) == ["Owen"])
    }
}

/// Loading it on the Family tab: planners only, by the household's day, and quiet on failure.
@MainActor
struct EngagementStoreTests {
    private func household(timeZone: String, weekStart: Int = 7, owner: UUID = .previewUser) -> Household {
        var settings = HouseholdSettings()
        settings.timeZone = timeZone
        settings.weekStart = weekStart
        return Household(id: Household.sample.id, name: "The Smiths", owner: owner, settings: settings)
    }

    @Test func aPlannerAsksForThisWeekAndTheLastFourWeeksByTheHouseholdsDay() async throws {
        // 2026-11-05 03:00 UTC is still Wednesday, November 4 in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_793_847_600)
        let asked = Mutex<[(UUID, CalendarDay, CalendarDay)]>([])
        let home = household(timeZone: "America/Los_Angeles")
        let nora = try #require(Member.sampleFamily.last)
        var client = HouseholdClient.fake(myHousehold: { home }, members: { _ in Member.sampleFamily })
        client.engagement = { id, from, to in
            asked.withLock { $0.append((id, from, to)) }
            return EngagementFacts(members: [EngagementCounts(memberID: nora.id, rated: 2)])
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadEngagement(now: now)

        let calls = asked.withLock { $0 }.sorted { $0.1 < $1.1 }
        #expect(calls.map(\.0) == [home.id, home.id])
        #expect(calls.map(\.1) == [CalendarDay(year: 2026, month: 10, day: 8),
                                   CalendarDay(year: 2026, month: 11, day: 1)])
        #expect(calls.map(\.2) == [CalendarDay(year: 2026, month: 11, day: 4),
                                   CalendarDay(year: 2026, month: 11, day: 7)])
        #expect(store.engagement?.map(\.member.id) == [nora.id])
    }

    @Test func someoneWhoDoesntPlanNeverAsks() async {
        let calls = Mutex(0)
        let home = household(timeZone: "America/New_York", owner: UUID())
        var client = HouseholdClient.fake(myHousehold: { home }, members: { _ in Member.sampleFamily })
        client.engagement = { _, _, _ in
            calls.withLock { $0 += 1 }
            return EngagementFacts()
        }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        await store.loadEngagement()
        #expect(calls.withLock { $0 } == 0)
        #expect(store.engagement == nil)
    }

    @Test func aFailedLoadStaysQuietAndKeepsWhatWasShown() async {
        let failing = Mutex(false)
        let nora = Member.sampleFamily[4]
        var client = HouseholdClient.fake(myHousehold: { .sample }, members: { _ in Member.sampleFamily })
        client.engagement = { _, _, _ in
            if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return EngagementFacts(members: [EngagementCounts(memberID: nora.id, rated: 2)])
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadEngagement()
        let shown = store.engagement
        failing.withLock { $0 = true }
        await store.loadEngagement()

        #expect(shown?.isEmpty == false)
        #expect(store.engagement == shown)
        #expect(store.errorMessage == nil, "the section never puts an error on the Family tab")
    }

    @Test func aNewHouseholdDoesNotShowTheOldOnes() async {
        let current = Mutex(household(timeZone: "America/New_York"))
        let nora = Member.sampleFamily[4]
        var client = HouseholdClient.fake(myHousehold: { current.withLock { $0 } },
                                          members: { _ in Member.sampleFamily })
        client.engagement = { id, _, _ in
            guard id == Household.sample.id else { throw URLError(.notConnectedToInternet) }
            return EngagementFacts(members: [EngagementCounts(memberID: nora.id, rated: 1)])
        }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        await store.loadEngagement()
        #expect(store.engagement?.isEmpty == false)

        current.withLock {
            $0 = Household(id: UUID(), name: "Real family", owner: .previewUser, settings: $0.planningSettings)
        }
        await store.load()
        await store.loadEngagement()
        #expect(store.engagement == nil)
    }
}
