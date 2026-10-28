import Foundation
import Testing
@testable import Foon

struct DinnerLogTests {
    @Test func decodesALogWithItsNightMealAndReactions() throws {
        let json = #"""
        {"id":"6B1A2B49-8F7C-4E52-9C1F-3A1D2E4F5A61","night_id":"0B2C7E7A-6D18-4A51-8E7C-2F6A9B1C3D4E",
         "meal_id":"9E1F2A3B-4C5D-4E6F-8A7B-1C2D3E4F5A6B","quick_pick":null,"cooked_by_member_id":null,
         "leftovers":true,"verified":false,"plan_nights":{"date":"2026-11-03"},"meals":{"name":"Chili"},
         "reactions":[{"member_id":"1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D","reaction":"not_for_me","off_tonight":true,
                       "comment":null,"created_at":"2026-11-03T23:10:00Z"}]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let log = try decoder.decode(DinnerLog.self, from: Data(json.utf8))
        #expect(log.date == CalendarDay(year: 2026, month: 11, day: 3))
        #expect(log.mealName == "Chili")
        #expect(!log.verified)
        #expect(log.leftovers == true)
        let reaction = try #require(log.reactions.first)
        #expect(reaction.kind == .notForMe)
        #expect(reaction.offTonight)
        #expect(log.reaction(of: reaction.memberID) == reaction)
    }

    @Test func aQuickPickNightHasNoMealAndNoReactions() throws {
        let json = #"""
        {"id":"6B1A2B49-8F7C-4E52-9C1F-3A1D2E4F5A61","night_id":"0B2C7E7A-6D18-4A51-8E7C-2F6A9B1C3D4E",
         "meal_id":null,"quick_pick":"takeout","cooked_by_member_id":null,"leftovers":null,"verified":true,
         "plan_nights":{"date":"2026-11-03"},"meals":null,"reactions":[]}
        """#
        let log = try JSONDecoder().decode(DinnerLog.self, from: Data(json.utf8))
        #expect(log.quickPick == .takeout)
        #expect(log.mealName == nil)
        #expect(log.reactions.isEmpty)
    }

    @Test func eachCorrectionSendsOnlyItsOwnColumns() throws {
        func json(_ correction: DinnerCorrection) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(correction)) as? [String: Any] ?? [:]
        }
        let dish = try json(.dish(mealID: nil, quickPick: .takeout))
        #expect(Set(dish.keys) == ["meal_id", "quick_pick"], "switching to a quick pick clears the meal, nothing else")
        #expect(dish["quick_pick"] as? String == "takeout")
        #expect(dish["meal_id"] is NSNull)
        let extras = try json(.extras(leftovers: true, cookedByMemberID: nil))
        #expect(Set(extras.keys) == ["leftovers", "cooked_by_member_id"], "the dish someone else set is left alone")
    }

    @Test func reactionsAreAboutTheFood() {
        #expect(ReactionKind.allCases.map(\.title) == ["Favorite", "Good", "Not for me", "Tired of it"])
    }
}

struct HouseholdTimeZoneTests {
    @Test func theTimeZoneRoundTripsAndJunkIsDropped() throws {
        var settings = HouseholdSettings()
        settings.timeZone = "America/Chicago"
        let decoded = try JSONDecoder().decode(HouseholdSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.timeZone == "America/Chicago")
        let junk = try JSONDecoder().decode(HouseholdSettings.self, from: Data(#"{"time_zone":"Mars/Base"}"#.utf8))
        #expect(junk.timeZone == nil)
        let none = String(decoding: try JSONEncoder().encode(HouseholdSettings()), as: UTF8.self)
        #expect(!none.contains("time_zone"), "no time zone is left for the server's default, not written as null")
    }
}
