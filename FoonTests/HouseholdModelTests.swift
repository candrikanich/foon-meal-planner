import Foundation
import Testing
@testable import Foon

struct CalendarDayTests {
    @Test func roundTripsAsAPostgresDate() throws {
        let day = CalendarDay(year: 2026, month: 12, day: 20)
        let encoded = try JSONEncoder().encode(day)
        #expect(String(data: encoded, encoding: .utf8) == "\"2026-12-20\"")
        #expect(try JSONDecoder().decode(CalendarDay.self, from: encoded) == day)
    }

    @Test func rejectsMalformedDates() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalendarDay.self, from: Data("\"12/20/2026\"".utf8))
        }
    }

    // Local midnight east of UTC is the previous day in UTC; the day must not shift.
    @Test func keepsTheLocalDayInAnyTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let localMidnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 20)))
        #expect(CalendarDay(localMidnight, calendar: calendar) == CalendarDay(year: 2026, month: 12, day: 20))
        #expect(CalendarDay(year: 2026, month: 12, day: 20).date(in: calendar) == localMidnight)
    }
}

struct MemberDecodingTests {
    // A row exactly as PostgREST returns it.
    private let row = """
    {"id": "00000000-0000-0000-0000-0000000000a1", "household_id": "00000000-0000-0000-0000-0000000000a0",
     "first_name": "Nora", "avatar": "🦊", "role": "member", "status": "away", "away_until": "2026-12-20",
     "user_id": null, "age_group": "kid", "guardian": false, "attendance_defaults": {}, "notification_prefs": {},
     "created_at": "2026-10-26T18:00:00.123456+00:00", "updated_at": "2026-10-26T18:00:00.123456+00:00"}
    """

    @Test func decodesAPostgRESTRow() throws {
        let member = try JSONDecoder().decode(Member.self, from: Data(row.utf8))
        #expect(member.firstName == "Nora")
        #expect(member.ageGroup == .kid)
        #expect(member.status == .away)
        #expect(member.awayUntil == CalendarDay(year: 2026, month: 12, day: 20))
        #expect(member.userID == nil)
        #expect(!member.guardian)
    }
}

struct MemberDraftTests {
    @Test func trimsAndAcceptsAName() throws {
        var draft = MemberDraft()
        draft.firstName = "  Nora "
        #expect(draft.validated()?.firstName == "Nora")
    }

    @Test(arguments: ["", "   ", String(repeating: "a", count: 31)])
    func rejectsNamesOutsideOneToThirtyCharacters(name: String) {
        var draft = MemberDraft()
        draft.firstName = name
        #expect(draft.validated() == nil)
    }

    @Test func kidsAreNeverGuardians() throws {
        var draft = MemberDraft()
        draft.firstName = "Nora"
        draft.guardian = true
        draft.ageGroup = .kid
        #expect(draft.validated()?.guardian == false)
    }

    @Test func aReturnDateOnlyAppliesWhileAway() throws {
        var draft = MemberDraft()
        draft.firstName = "Owen"
        draft.awayUntil = CalendarDay(year: 2026, month: 12, day: 20)
        #expect(draft.validated()?.awayUntil == nil)
        draft.status = .away
        #expect(draft.validated()?.awayUntil == CalendarDay(year: 2026, month: 12, day: 20))
    }

    @Test func startsFromAnExistingMember() {
        let member = Member.fixture(firstName: "Owen", ageGroup: .adult, guardian: true, role: .planner)
        let draft = MemberDraft(member)
        #expect(draft.firstName == "Owen")
        #expect(draft.guardian)
        #expect(draft.role == .planner)
    }
}

struct HouseholdNameTests {
    @Test(arguments: [("  The Smiths ", "The Smiths"), ("", nil), (String(repeating: "x", count: 51), nil)])
    func validatesHouseholdNames(input: String, expected: String?) {
        #expect(Household.validatedName(input) == expected)
    }
}

struct MemberChangesTests {
    @Test func listsOnlyChangedFields() throws {
        let member = Member.fixture(firstName: "Owen", avatar: "🦊", ageGroup: .kid, status: .away,
                                    awayUntil: CalendarDay(year: 2026, month: 12, day: 20))
        var draft = MemberDraft(member)
        draft.status = .active
        let changes = try #require(draft.validated()).changes(from: member)
        #expect(changes == MemberChanges(status: .active, awayUntil: .some(nil)))
    }

    @Test func encodesClearedValuesAsNullAndSkipsTheRest() throws {
        let json = try JSONEncoder().encode(MemberChanges(avatar: .some(nil), status: .active))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["avatar", "status"])
        #expect(object["avatar"] is NSNull)
    }

    @Test func noChangesIsEmpty() {
        let member = Member.fixture(firstName: "Owen")
        #expect(MemberDraft(member).changes(from: member).isEmpty)
    }
}
