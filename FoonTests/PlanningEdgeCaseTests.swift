import Foundation
import Testing
@testable import Foon

/// Real families that don't fit the defaults (#30): a tiny library, a household of one, a household of ten.
struct PlanningEdgeCaseTests {
    private let start = CalendarDay(year: 2026, month: 11, day: 1)

    private func week(_ family: [UUID]) -> [PlanningNight] {
        (0..<7).map { offset in
            PlanningNight(id: UUID(), date: start.adding(days: offset),
                          attendance: Dictionary(uniqueKeysWithValues: family.map { ($0, true) }))
        }
    }

    private func inputs(_ nights: [PlanningNight], meals: [LibraryMeal]) -> PlanningInputs {
        var settings = HouseholdSettings()
        settings.leftoverNights = 0
        return PlanningInputs(nights: nights, meals: meals,
                              history: meals.map { MealHistory(mealID: $0.id, timesMade: 2, lastMade: start.adding(days: -30)) },
                              settings: settings)
    }

    @Test func aSmallLibraryFillsWhatItCanAndLeavesTheRestOpen() {
        let meals = (0..<3).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let draft = BuildMyWeek.draft(inputs(week([UUID()]), meals: meals), seed: 1)
        #expect(draft.compactMap(\.pick).count == 3)
        #expect(Set(draft.compactMap(\.pick?.mealID)).count == 3, "no dish twice to stretch the week")
        #expect(draft.filter { $0.pick == nil }.allSatisfy { $0.reason == .nothingFits })
    }

    @Test(arguments: [1, 10])
    func householdsOfOneAndOfTenGetAFullWeek(size: Int) {
        let family = (0..<size).map { _ in UUID() }
        let meals = (0..<10).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let draft = BuildMyWeek.draft(inputs(week(family), meals: meals), seed: 2)
        #expect(draft.allSatisfy { $0.pick != nil })
    }

    @Test func aHouseholdOfTenPlansAroundWhoIsHome() {
        // Owen can't stand liver; it can only land on the night he's away.
        let family = (0..<10).map { _ in UUID() }
        var nights = week(family)
        nights[3].attendance[family[7]] = false
        let liver = LibraryMeal.fixture(name: "Liver")
        let meals = [liver] + (0..<9).map { LibraryMeal.fixture(name: "Dish \($0)") }
        var planning = inputs(nights, meals: meals)
        planning.notForMe = [liver.id: [family[7]: 1]]
        for seed in UInt64(0)..<50 {
            let draft = BuildMyWeek.draft(planning, seed: seed)
            #expect(draft.allSatisfy { $0.pick != nil })
            #expect(draft.indices.allSatisfy { draft[$0].pick != .meal(liver.id) || $0 == 3 })
        }
    }

    @Test func aNightNobodyIsHomeGetsNoDinner() {
        let me = UUID()
        var nights = week([me])
        nights[2].attendance[me] = false
        let meals = (0..<10).map { LibraryMeal.fixture(name: "Dish \($0)") }
        let draft = BuildMyWeek.draft(inputs(nights, meals: meals), seed: 4)
        #expect(draft[2].pick == nil)
        #expect(draft[2].reason == .nobodyHome)
        #expect(draft.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.pick != nil })
        #expect(BuildMyWeek.shuffle(night: nights[2].id, inputs: inputs(nights, meals: meals), seed: 1) == nil)
        #expect(PlanReason.nobodyHome.text == "Nobody's home")
    }
}

struct StarterIdeaTests {
    @Test func starterIdeasArePopularDishesNotYetInTheLibrary() {
        let tacos = CatalogDish.fixture(name: "Tacos", popular: true, sortOrder: 8)
        let chili = CatalogDish.fixture(name: "Chili", popular: false, sortOrder: 2)
        let burgers = CatalogDish.fixture(name: "Burgers", popular: true, sortOrder: 15)
        let ziti = CatalogDish.fixture(name: "Ziti", popular: true, sortOrder: 4)
        let library = [LibraryMeal.fixture(name: "Our tacos", catalogMealID: tacos.id)]
        let ideas = LibraryQuery.starterIdeas([tacos, chili, burgers, ziti], library: library, count: 3)
        #expect(ideas.map(\.name) == ["Ziti", "Burgers", "Chili"])
    }

    @Test func unusedMealsCountOnlyWhatIsInRotationAndNotAlreadyPlanned() {
        let meals = (0..<5).map { LibraryMeal.fixture(name: "Dish \($0)") }
            + [LibraryMeal.fixture(name: "Old", status: .archived)]
        #expect(LibraryQuery.unusedInRotation(meals, planned: [meals[0].id, meals[1].id]) == 3)
    }
}

struct AttendanceOverflowTests {
    private func attendees(_ count: Int) -> [DayCardModel.Attendee] {
        (0..<count).map { .init(memberID: UUID(), firstName: "Kid \($0)", avatar: nil, isHome: $0 % 3 != 0) }
    }

    @Test func someoneAwayIsNeverHiddenBehindTheCount() {
        var family = (0..<10).map { DayCardModel.Attendee(memberID: UUID(), firstName: "Kid \($0)", avatar: nil,
                                                          isHome: true) }
        family[8] = DayCardModel.Attendee(memberID: family[8].memberID, firstName: "Owen", avatar: nil, isHome: false)
        let shown = DayCardText.visibleAttendees(family)
        #expect(shown.visible.first?.firstName == "Owen")
        #expect(shown.visible.count == 6)
    }

    @Test func aBigFamilyShowsSixAvatarsAndACount() {
        let shown = DayCardText.visibleAttendees(attendees(10))
        #expect(shown.visible.count == 6)
        #expect(shown.hidden == 4)
    }

    @Test(arguments: [1, 6])
    func smallFamiliesShowEveryone(size: Int) {
        let shown = DayCardText.visibleAttendees(attendees(size))
        #expect(shown.visible.count == size)
        #expect(shown.hidden == 0)
    }

    @Test func voiceOverStillNamesEveryone() {
        let today = CalendarDay(year: 2026, month: 11, day: 4)
        let card = DayCardModel(date: today, effort: .normal, slot: .empty, attendance: attendees(10), badges: [],
                                isLocked: false)
        let summary = DayCardText.accessibilitySummary(card, today: today, calendar: Calendar(identifier: .gregorian))
        #expect((0..<10).allSatisfy { summary.contains("Kid \($0)") })
    }
}
