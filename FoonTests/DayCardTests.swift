import Foundation
import Testing
@testable import Foon

struct DayCardTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()
    private let today = CalendarDay(year: 2026, month: 11, day: 4)  // a Wednesday

    @Test func namesTonightAndTomorrow() {
        #expect(DayCardText.dayLabel(for: today, today: today, calendar: calendar) == "Tonight")
        #expect(DayCardText.dayLabel(for: today.adding(days: 1, calendar: calendar), today: today, calendar: calendar)
            == "Tomorrow")
    }

    @Test func otherDaysUseTheWeekday() {
        #expect(DayCardText.dayLabel(for: today.adding(days: 3, calendar: calendar), today: today, calendar: calendar)
            == "Saturday")
        #expect(DayCardText.dayLabel(for: today.adding(days: -1, calendar: calendar), today: today, calendar: calendar)
            == "Tuesday")
    }

    @Test func dateLabelIsShort() {
        #expect(DayCardText.dateLabel(for: today, calendar: calendar) == "Nov 4")
    }

    @Test(arguments: [(NightEffort.normal, "Normal"), (.rushed, "Rushed"), (.full, "Full evening"), (.event, "Event")])
    func effortLabels(effort: NightEffort, label: String) {
        #expect(DayCardText.effortLabel(effort) == label)
    }

    @Test func effortCyclesNormalRushedFullEvent() {
        #expect(NightEffort.normal.next == .rushed)
        #expect(NightEffort.rushed.next == .full)
        #expect(NightEffort.full.next == .event)
        #expect(NightEffort.event.next == .normal)
    }

    @Test(arguments: [(QuickPick.leftovers, "Leftovers"), (.takeout, "Takeout"), (.eatOut, "Eat out"),
                      (.fendForYourselves, "Fend for yourselves"), (.freezerRaid, "Freezer raid")])
    func quickPickLabels(pick: QuickPick, label: String) {
        #expect(DayCardText.quickPickLabel(pick) == label)
    }

    @Test func accessibilitySummaryReadsLikeASentence() {
        let card = DayCardModel(
            date: today,
            effort: .rushed,
            slot: .meal(name: "Tacos", photoURL: nil, reason: "Nora's favorite"),
            attendance: [.init(memberID: UUID(), firstName: "Nora", avatar: "🐢", isHome: true),
                         .init(memberID: UUID(), firstName: "Owen", avatar: nil, isHome: false)],
            badges: [.allergy("Contains milk (Nora)")],
            isLocked: true
        )
        #expect(DayCardText.accessibilitySummary(card, today: today, calendar: calendar)
            == "Tonight, Nov 4. Tacos, Nora's favorite. Rushed. Home: Nora. Away: Owen. Contains milk (Nora). Locked.")
    }

    @Test func servingNotesAreReadToo() {
        let card = DayCardModel(date: today, effort: .normal, slot: .meal(name: "Chili", photoURL: nil, reason: nil),
                                attendance: [], badges: [], isLocked: false, servingNotes: ["Nora: keep it separate"])
        #expect(DayCardText.accessibilitySummary(card, today: today, calendar: calendar)
            == "Tonight, Nov 4. Chili. Normal. Nora: keep it separate.")
    }

    @Test func anEmptyNightSaysSo() {
        let card = DayCardModel(date: today, effort: .normal, slot: .empty, attendance: [], badges: [], isLocked: false)
        #expect(DayCardText.accessibilitySummary(card, today: today, calendar: calendar)
            == "Tonight, Nov 4. Nothing planned yet. Normal.")
    }
}
