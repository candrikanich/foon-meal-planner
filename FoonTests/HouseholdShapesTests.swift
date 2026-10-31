import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

/// Household shapes (#49): the parts that aren't food rules. Those have FoodRulesTests.
struct AwayPatternTests {
    private func day(_ number: Int, month: Int = 11) -> CalendarDay { CalendarDay(year: 2026, month: month, day: number) }
    /// A Monday.
    private var everyOtherWeek: AwayPattern { AwayPattern(from: day(2)) }
    /// A Friday.
    private var everyOtherWeekend: AwayPattern { AwayPattern(from: day(6), days: AwayPattern.weekend) }

    /// The same dates `public.away_pattern_covers` is tested with (34_household_shapes.test.sql), so they can't drift apart.
    @Test func awayEveryOtherWeekFromTheFirstNight() {
        #expect(everyOtherWeek.covers(day(2)))
        #expect(everyOtherWeek.covers(day(8)), "all seven nights")
        #expect(!everyOtherWeek.covers(day(9)), "home the week after")
        #expect(everyOtherWeek.covers(day(16)), "out again the week after that")
        #expect(!everyOtherWeek.covers(day(1)), "not before it starts")
        #expect(!everyOtherWeek.covers(day(26, month: 10)), "even on a night that would have lined up")
    }

    @Test func everyThreeWeeksSkipsTwo() {
        let pattern = AwayPattern(everyWeeks: 3, from: day(2))
        #expect(!pattern.covers(day(16)))
        #expect(pattern.covers(day(23)))
    }

    @Test func daysNarrowItToAWeekend() {
        #expect(everyOtherWeekend.covers(day(8)), "the Sunday")
        #expect(!everyOtherWeekend.covers(day(9)), "not the rest of that stretch")
        #expect(!everyOtherWeekend.covers(day(13)), "home on the weekend between")
        #expect(everyOtherWeekend.covers(day(20)), "out on the next one")
    }

    /// Same dates as the SQL. Seven-night stretches from a Saturday would give that weekend's Saturday and Sunday, then the
    /// Friday of the weekend they're home.
    @Test(arguments: [7, 8])
    func aWeekendStartedOnItsSaturdayOrSundayIsStillThatWeekend(start: Int) {
        let pattern = AwayPattern(from: day(start), days: AwayPattern.weekend)
        for away in [6, 7, 8, 20, 21, 22] { #expect(pattern.covers(day(away)), "\(away)") }
        for home in [13, 14, 15, 27, 28, 29] { #expect(!pattern.covers(day(home)), "\(home)") }
    }

    @Test func pickingAWeekendMovesTheDateToItsFriday() {
        #expect(AwayPattern(from: day(7), days: AwayPattern.weekend).snapped().from == day(6))
        #expect(AwayPattern(from: day(8), days: AwayPattern.weekend).snapped().from == day(6))
        #expect(AwayPattern(from: day(6), days: AwayPattern.weekend).snapped().from == day(6))
        #expect(AwayPattern(from: day(4), days: AwayPattern.weekend).snapped().from == day(30, month: 10), "a Wednesday's last Friday")
        #expect(AwayPattern(from: day(7)).snapped().from == day(7), "the whole week starts where it says")
    }

    @Test func aSavedDraftHasTheFriday() {
        var draft = MemberDraft()
        draft.firstName = "Owen"
        draft.awayPattern = AwayPattern(from: day(7), days: AwayPattern.weekend)
        #expect(draft.validated()?.awayPattern?.from == day(6))
    }

    /// The table in 34_household_shapes.test.sql. A hand-written value means the same on both sides, and a bad one puts
    /// nobody away.
    @Test(arguments: [
        #""every other week""#, "[]", #"{"every_weeks": 2, "from": "soon"}"#, #"{"every_weeks": 0, "from": "2026-11-02"}"#,
        #"{"every_weeks": 5, "from": "2026-11-02"}"#, #"{"every_weeks": 2.5, "from": "2026-11-02"}"#,
        #"{"every_weeks": "2", "from": "2026-11-02"}"#, #"{"from": "2026-11-02"}"#, #"{"every_weeks": 2}"#,
        #"{"every_weeks": 2, "from": "infinity"}"#, #"{"every_weeks": 2, "from": "Nov 2 2026"}"#,
        #"{"every_weeks": 2, "from": "11/02/2026"}"#, #"{"every_weeks": 2, "from": "2026-11-2"}"#,
        #"{"every_weeks": 2, "from": 20261102}"#, #"{"every_weeks": 2, "from": "2026-02-31"}"#,
        #"{"every_weeks": 2, "from": "2026-11-02", "days": "x"}"#, #"{"every_weeks": 2, "from": "2026-11-02", "days": ["x"]}"#,
        #"{"every_weeks": 2, "from": "2026-11-02", "days": [9]}"#, #"{"every_weeks": 2, "from": "2026-11-02", "days": [1, "x"]}"#,
        #"{"every_weeks": 2, "from": "2026-11-02", "days": null}"#,
    ])
    func aBadValueIsNoPattern(pattern: String) throws {
        let read = try JSONDecoder().decode(AttendanceDefaults.self, from: Data(#"{"away_pattern": \#(pattern)}"#.utf8))
        #expect(read.awayPattern == nil)
    }

    @Test func theValuesThatLookOddButAreFine() throws {
        func read(_ pattern: String) throws -> AwayPattern? {
            try JSONDecoder().decode(AttendanceDefaults.self, from: Data(#"{"away_pattern": \#(pattern)}"#.utf8)).awayPattern
        }
        #expect(try read(#"{"every_weeks": 2.0, "from": "2026-11-02"}"#)?.covers(day(2)) == true)
        #expect(try read(#"{"every_weeks": 2, "from": "2026-11-02", "days": []}"#)?.covers(day(2)) == true)
    }

    @Test func theNextNightOutIsWhatTheEditorShows() {
        #expect(everyOtherWeek.nextNight(onOrAfter: day(9)) == day(16), "from a home week, the next away week")
        #expect(everyOtherWeek.nextNight(onOrAfter: day(4)) == day(4), "during an away week, tonight")
        #expect(everyOtherWeek.nextNight(onOrAfter: day(1, month: 10)) == day(2), "before it starts, its first night")
        #expect(everyOtherWeekend.nextNight(onOrAfter: day(9)) == day(20))
        #expect(AwayPattern(everyWeeks: 4, from: day(6), days: AwayPattern.weekend).nextNight(onOrAfter: day(9))
            == CalendarDay(year: 2026, month: 12, day: 4))
    }

    @Test func aScheduleReadsItsPatternAndABadOneCostsNothingElse() throws {
        func decode(_ json: String) throws -> AttendanceDefaults {
            try JSONDecoder().decode(AttendanceDefaults.self, from: Data(json.utf8))
        }
        let good = try decode(#"{"usually_away": [1], "away_pattern": {"every_weeks": 2, "from": "2026-11-06", "days": [5, 6, 7]}}"#)
        #expect(good.awayPattern == everyOtherWeekend)
        #expect(good.usuallyAway == [1])
        for bad in [#""soon""#, #"{"every_weeks": 2}"#, #"{"every_weeks": 9, "from": "2026-11-02"}"#,
                    #"{"every_weeks": 2, "from": "whenever"}"#, "null"] {
            let read = try decode(#"{"usually_away": [1], "away_pattern": \#(bad)}"#)
            #expect(read.awayPattern == nil, "\(bad)")
            #expect(read.usuallyAway == [1], "\(bad)")
        }
    }

    private func owen(pattern: AwayPattern? = nil, usuallyAway: Set<Int> = [1]) -> Member {
        var member = Member.fixture(firstName: "Owen")
        member.attendanceDefaults = AttendanceDefaults(usuallyAway: usuallyAway, awayPattern: pattern)
        return member
    }

    private func json(_ changes: MemberChanges) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(changes), as: UTF8.self)
    }

    /// A stale phone changing the days mustn't put back the pattern it remembers, and the other way around.
    @Test func eachEditSendsOnlyTheKeyItChanged() throws {
        let member = owen(pattern: everyOtherWeek)
        var days = MemberDraft(member)
        days.usuallyAway = [1, 2]
        #expect(try json(days.changes(from: member)) == #"{"attendance_defaults":{"usually_away":[1,2]}}"#)
        #expect(member.applying(days.changes(from: member)).awayPattern == everyOtherWeek, "and shows the pattern kept")

        var pattern = MemberDraft(member)
        pattern.awayPattern = AwayPattern(everyWeeks: 3, from: day(2))
        #expect(try json(pattern.changes(from: member))
            == #"{"attendance_defaults":{"away_pattern":{"every_weeks":3,"from":"2026-11-02"}}}"#)
        let applied = member.applying(pattern.changes(from: member))
        #expect(applied.awayPattern?.everyWeeks == 3)
        #expect(applied.usuallyAway == [1], "and shows the days kept")

        var ended = MemberDraft(member)
        ended.awayPattern = nil
        #expect(try json(ended.changes(from: member)) == #"{"attendance_defaults":{"away_pattern":null}}"#,
                "null is what takes it away on the server")
        #expect(member.applying(ended.changes(from: member)).awayPattern == nil)
    }

    @Test func aSavedScheduleSaysSoAndIsntInUseWithoutThePattern() {
        let member = owen(pattern: everyOtherWeek, usuallyAway: [])
        let custody = AttendanceTemplate(id: UUID(), name: "Custody", schedules: [
            member.id: AttendanceDefaults(awayPattern: everyOtherWeek)
        ])
        #expect(custody.summary(members: [member]) == "Owen out every other week",
                "never Everyone home every night")
        #expect(custody.isInUse(by: [member]))

        var noPattern = Member.fixture(id: member.id, firstName: "Owen")
        noPattern.attendanceDefaults = AttendanceDefaults()
        #expect(!custody.isInUse(by: [noPattern]), "the same days without the pattern is a different schedule")
    }
}

struct EatsSeparatelyTests {
    @Test func aMemberReadsTheFlagAndOlderDataIsNoFlag() throws {
        func decode(_ extra: String) throws -> Member {
            try JSONDecoder().decode(Member.self, from: Data("""
            {"id": "\(UUID())", "household_id": "\(UUID())", "first_name": "Tot", "avatar": null, "age_group": "kid",
             "guardian": false, "role": "member", "status": "active", "away_until": null, "user_id": null\(extra)}
            """.utf8))
        }
        #expect(try decode("").eatsSeparately == false)
        #expect(try decode(#", "eats_separately": true"#).eatsSeparately == true)
    }

    @Test func aDraftSendsItOnlyWhenItChanged() throws {
        let tot = Member.fixture(firstName: "Tot")
        var draft = MemberDraft(tot)
        #expect(draft.changes(from: tot).isEmpty)
        draft.eatsSeparately = true
        let changes = draft.changes(from: tot)
        #expect(String(decoding: try JSONEncoder().encode(changes), as: UTF8.self) == #"{"eats_separately":true}"#)
        #expect(tot.applying(changes).eatsSeparately)

        let added = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
        #expect(added?["eats_separately"] as? Bool == true, "adding someone says so too")
    }

    @Test func theyArentAskedToRateOnAnyPhone() {
        var tot = Member.fixture(firstName: "Tot")
        tot.eatsSeparately = true
        let me = Member.fixture(firstName: "Ann", userID: UUID())
        let nora = Member.fixture(firstName: "Nora")
        #expect(DinnerPrompts.whoRates(among: [me, nora, tot]).map(\.id) == [me.id, nora.id])
        #expect(DinnerPrompts.rates(me))
        #expect(!DinnerPrompts.rates(tot))
    }

    /// "I want..." reads the same list: it's about ratings and votes, not asking.
    @Test func theyCanStillBeWhoAsksForADish() {
        var tot = Member.fixture(firstName: "Tot")
        tot.eatsSeparately = true
        let me = Member.fixture(firstName: "Ann", userID: UUID())
        #expect(DinnerPrompts.raters(home: [me, tot], me: me.id).map(\.id) == [me.id, tot.id])
    }

    private let weekStart = CalendarDay(year: 2026, month: 11, day: 1)

    private func wanted(_ request: DinnerRequest, members: [Member]) -> [WantedRequest] {
        RequestBoard.wanted([request], weekStart: weekStart, today: weekStart, members: members)
    }

    @Test func theirMeTooDoesntCountTowardPriority() {
        let (ann, ben, cleo) = (Member.fixture(firstName: "Ann"), Member.fixture(firstName: "Ben"), Member.fixture(firstName: "Cleo"))
        var tot = Member.fixture(firstName: "Tot")
        tot.eatsSeparately = true
        let meal = UUID()
        // Three of the four, but one of them's the toddler: two people out of a family of three is short of everyone.
        let request = DinnerRequest(requestedByMemberID: ann.id, mealID: meal, plusOnes: [ben.id, tot.id])
        #expect(wanted(request, members: [ann, ben, cleo, tot]).isEmpty)
        let everyone = DinnerRequest(requestedByMemberID: ann.id, mealID: meal, plusOnes: [ben.id, cleo.id, tot.id])
        #expect(wanted(everyone, members: [ann, ben, cleo, tot]).first?.wanters == [ann.id, ben.id, cleo.id])
    }

    @Test func nobodyHasToWaitOnThemForTheThreshold() {
        let (ann, ben) = (Member.fixture(firstName: "Ann"), Member.fixture(firstName: "Ben"))
        var tot = Member.fixture(firstName: "Tot")
        tot.eatsSeparately = true
        // Everyone who counts: without the flag, three in the family would need all three.
        let request = DinnerRequest(requestedByMemberID: ann.id, mealID: UUID(), plusOnes: [ben.id])
        #expect(wanted(request, members: [ann, ben, tot]).count == 1)
    }

    @MainActor
    @Test func aRefusedRatingSaysWhyNotCheckYourConnection() async {
        let night = UUID()
        var client = DinnerClient.preview
        client.react = { _, _, _ in throw PostgrestError(code: "FD004", message: "they eat separately") }
        let store = DinnerStore(householdID: UUID(), client: client)
        #expect(await store.react(nightID: night, memberID: UUID(), .good) == false)
        #expect(store.errorMessage == "They eat separately, so they don't rate dinners.")
    }
}

@MainActor
struct HiddenCommentsTests {
    private func comment(hidden: Bool = false, meal: UUID = UUID()) -> MealComment {
        MealComment(id: UUID(), mealID: meal, memberID: UUID(), text: "Too spicy", dinnerOn: CalendarDay(year: 2026, month: 11, day: 1),
                    hidden: hidden)
    }

    private func store(_ comments: [MealComment], hide: @escaping @Sendable (UUID, Bool) async throws -> Void = { _, _ in })
        -> LibraryStore {
        var client = LibraryClient.preview(meals: [])
        client.comments = { _ in comments }
        client.setCommentHidden = hide
        return LibraryStore(householdID: Household.sample.id, client: client)
    }

    @Test func aPlannerHidesOneAndBringsItBack() async {
        let spicy = comment()
        let store = store([spicy])
        await store.load(members: [])
        #expect(store.comments(for: spicy.mealID) == [spicy])
        #expect(await store.setCommentHidden(spicy, hidden: true))
        #expect(store.comments(for: spicy.mealID).first?.hidden == true, "still there for a planner, marked")
        #expect(await store.setCommentHidden(spicy, hidden: false))
        #expect(store.comments(for: spicy.mealID).first?.hidden == false)
    }

    /// A feature with nothing in it yet can't be what stops the Library opening.
    @Test func aFailedReadOfCommentsDoesntFailTheLibrary() async {
        let meal = LibraryMeal.fixture(name: "Chili")
        var client = LibraryClient.preview(meals: [meal])
        client.comments = { _ in throw URLError(.notConnectedToInternet) }
        let store = LibraryStore(householdID: Household.sample.id, client: client)
        await store.load(members: [])
        #expect(store.errorMessage == nil)
        #expect(store.meals.map(\.name) == ["Chili"])
        #expect(store.comments.isEmpty)
    }

    @Test func aRefreshThatCantReadCommentsKeepsTheOthersAndWhatItHad() async {
        let spicy = comment()
        var client = LibraryClient.preview(meals: [])
        let reads = Mutex(0)
        client.comments = { _ in
            let read = reads.withLock { count in
                count += 1
                return count
            }
            if read > 1 { throw URLError(.notConnectedToInternet) }
            return [spicy]
        }
        client.likes = { _ in [MealLikes(mealID: spicy.mealID, likes: 3)] }
        let store = LibraryStore(householdID: Household.sample.id, client: client)
        await store.load(members: [])
        await store.refreshReactions(members: [])
        #expect(store.comments == [spicy])
        #expect(store.reactions.likes[spicy.mealID] == 3)
    }

    @Test func aRefusalSaysWhoCanAndLeavesItAsItWas() async {
        let spicy = comment()
        let store = store([spicy]) { _, _ in throw PostgrestError(code: "42501", message: "only planners hide comments") }
        await store.load(members: [])
        #expect(await store.setCommentHidden(spicy, hidden: true) == false)
        #expect(store.errorMessage == "Only planners can hide a comment.")
        #expect(store.comments(for: spicy.mealID).first?.hidden == false)
    }

    @Test func aFailureSaysCheckYourConnection() async {
        let spicy = comment()
        let store = store([spicy]) { _, _ in throw URLError(.notConnectedToInternet) }
        await store.load(members: [])
        #expect(await store.setCommentHidden(spicy, hidden: true) == false)
        #expect(store.errorMessage == "Couldn't change that comment. Check your connection and try again.")
    }

    @Test func aCommentReadsFromTheView() throws {
        let read = try JSONDecoder().decode(MealComment.self, from: Data("""
        {"id": "\(UUID())", "meal_id": "\(UUID())", "member_id": "\(UUID())", "comment": "Too spicy",
         "dinner_on": "2026-11-01", "hidden": true}
        """.utf8))
        #expect(read.text == "Too spicy")
        #expect(read.hidden)
    }
}
