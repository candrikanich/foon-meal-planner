import Foundation
import SwiftData
import Testing
@testable import Foon

struct ListNightLabelTests {
    private static let english = Locale(identifier: "en_US")
    /// A zone behind UTC: a date parsed as UTC midnight would land on the day before here.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func label(_ nights: [ListNightRef]) -> ListNightLabel? {
        ListNightLabel(nights, locale: Self.english, calendar: Self.calendar)
    }

    private func night(_ date: String, _ meal: String? = nil) -> ListNightRef { ListNightRef(date: date, mealName: meal) }

    @Test func noNightsMeansNoLabel() {
        #expect(label([]) == nil)
    }

    @Test func oneNightReadsDayThenDish() {
        let one = label([night("2026-11-20", "Tacos")])
        #expect(one?.text == "Fri · Tacos")
        #expect(one?.spoken == "For Friday, Tacos")
    }

    @Test func severalNightsAreSortedByDate() {
        let several = label([night("2026-11-20", "Tacos"), night("2026-11-17", "Chili")])
        #expect(several?.text == "Tue · Chili, Fri · Tacos")
        #expect(several?.spoken == "For Tuesday, Chili; Friday, Tacos")
    }

    @Test func theSameNightAndDishReadsOnce() {
        let twice = label([night("2026-11-17", "Chili"), night("2026-11-17", "Chili")])
        #expect(twice?.text == "Tue · Chili")
    }

    @Test func aNightWithNoDishShowsJustTheDay() {
        let mixed = label([night("2026-11-18"), night("2026-11-20", "Tacos")])
        #expect(mixed?.text == "Wed, Fri · Tacos")
        #expect(mixed?.spoken == "For Wednesday; Friday, Tacos")
    }

    @Test func theDateIsACalendarDayInAnyTimeZone() {
        for zone in ["Pacific/Auckland", "America/Los_Angeles", "UTC"] {
            var calendar = Self.calendar
            calendar.timeZone = TimeZone(identifier: zone)!
            #expect(ListNightLabel([night("2026-11-17")], locale: Self.english, calendar: calendar)?.text == "Tue", "\(zone)")
        }
    }

    @Test func weekdaysFollowTheLocale() {
        let french = ListNightLabel([night("2026-11-17", "Chili")], locale: Locale(identifier: "fr_FR"), calendar: Self.calendar)
        #expect(french?.spoken.contains("mardi") == true)
    }

    @Test func anUnreadableDateIsLeftOut() {
        #expect(label([night("soon", "Chili")]) == nil)
    }
}

struct ListEntryNightsTests {
    private func line(nights: [ListNightRef], checkedAt: Date? = nil) -> CachedListItem {
        CachedListItem(id: UUID(), householdID: UUID(), itemID: UUID(), itemName: "Cheddar", list: .weekly,
                       urgency: .whenever, source: .plan, note: nil, checkedAt: checkedAt, nights: nights)
    }

    private let nights = [ListNightRef(date: "2026-11-20", mealName: "Tacos"), ListNightRef(date: "2026-11-17", mealName: "Chili")]

    @Test func anEntryCarriesItsLinesNights() {
        let entry = ListEntry.entries(lines: [line(nights: nights)], items: []).first
        #expect(entry?.nights.map(\.date) == ["2026-11-17", "2026-11-20"])
        #expect(entry?.nightLabel != nil)
    }

    @Test func aCheckedOffEntryShowsNoLabel() {
        let entry = ListEntry.entries(lines: [line(nights: nights, checkedAt: .now)], items: []).first
        #expect(entry?.nightLabel == nil)
    }

    @Test func aHandAddedEntryShowsNoLabel() {
        #expect(ListEntry.entries(lines: [line(nights: [])], items: []).first?.nightLabel == nil)
    }

    @Test func aWeeklyLineFoldedUnderATonightLineStillShowsItsNights() throws {
        let weekly = try #require(ListEntry.entries(lines: [line(nights: nights)], items: []).first)
        let lead = ListEntry(lineID: UUID(), itemID: weekly.itemID, name: "Cheddar", list: .quick, urgency: .tonight,
                              quantity: nil, lineNote: nil, itemNote: nil, category: .other, checkedAt: nil,
                              keepOnHand: false, folded: [weekly])
        #expect(lead.nightLabel != nil)
    }
}
