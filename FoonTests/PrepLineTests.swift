import Foundation
import Testing
@testable import Foon

/// One prep line with the cook window (#340). Times are wall-clock minutes read in GMT, so the device's zone and
/// daylight saving can't move them (the formatters are pinned to GMT); only the locale decides 12 or 24-hour.
struct PrepLineTests {
    private let enUS = Locale(identifier: "en_US")
    private let enGB = Locale(identifier: "en_GB")
    private let thaw = "Thaw the chicken · 1 day ahead"

    private func window(start: Int, dinner: Int, estimate: Bool = false) -> StartCooking {
        StartCooking(cookMinutes: dinner - start, isEstimate: estimate, startMinute: start, dinnerMinute: dinner)
    }

    /// The system's time formats put narrow spaces before PM and around the dash.
    private func plain(_ text: String?) -> String? {
        text?.spacesPlain
    }

    private func line(_ prep: String?, _ start: StartCooking?, _ locale: Locale? = nil) -> PrepLine? {
        PrepLine.make(prep: prep, start: start, locale: locale ?? enUS)
    }

    @Test func bothJoinWithADot() {
        let both = line(thaw, window(start: 15 * 60, dinner: 18 * 60))
        #expect(plain(both?.text) == "Thaw the chicken · 1 day ahead · Cook 3:00 – 6:00 PM")
    }

    @Test func bothAreReadAsFullSentences() {
        let both = line("Thaw tonight", window(start: 15 * 60, dinner: 18 * 60))
        #expect(plain(both?.spoken) == "Thaw tonight. Start cooking at 3:00 PM for dinner at 6:00 PM")
    }

    @Test func onlyPrepIsJustThePrep() {
        let prep = line(thaw, nil)
        #expect(prep == PrepLine(thaw))
        #expect(prep?.spoken == thaw)
    }

    @Test func onlyTimesIsJustTheWindow() {
        let times = line(nil, window(start: 15 * 60, dinner: 18 * 60))
        #expect(plain(times?.text) == "Cook 3:00 – 6:00 PM")
        #expect(plain(times?.spoken) == "Start cooking at 3:00 PM for dinner at 6:00 PM")
    }

    @Test func neitherIsNoLine() {
        #expect(line(nil, nil) == nil)
    }

    @Test func anEstimateSaysAround() {
        let guess = line("Thaw", window(start: 17 * 60 + 30, dinner: 18 * 60, estimate: true))
        #expect(plain(guess?.text) == "Thaw · Cook around 5:30 – 6:00 PM")
        #expect(plain(guess?.spoken) == "Thaw. Start cooking around 5:30 PM for dinner at 6:00 PM")
    }

    @Test func aMorningStartSaysFromInsteadOfALongRange() {
        let slow = line(nil, window(start: 9 * 60, dinner: 18 * 60))
        #expect(plain(slow?.text) == "Cook from 9:00 AM")
        #expect(plain(slow?.spoken) == "Start cooking at 9:00 AM for dinner at 6:00 PM")
        #expect(plain(line(nil, window(start: 9 * 60, dinner: 18 * 60, estimate: true))?.text) == "Cook from around 9:00 AM")
    }

    @Test func noonIsTheFirstStartThatKeepsTheRange() {
        #expect(plain(line(nil, window(start: 11 * 60 + 59, dinner: 18 * 60))?.text) == "Cook from 11:59 AM")
        #expect(plain(line(nil, window(start: 12 * 60, dinner: 18 * 60))?.text) == "Cook 12:00 – 6:00 PM")
    }

    @Test func aTwentyFourHourLocaleReadsThatWay() {
        let both = line("Thaw", window(start: 15 * 60, dinner: 18 * 60), enGB)
        #expect(plain(both?.text) == "Thaw · Cook 15:00 – 18:00")
        #expect(plain(both?.spoken) == "Thaw. Start cooking at 15:00 for dinner at 18:00")
    }

    // MARK: On the card

    private func meal(_ prep: [PrepStep], tags: [MealTag] = [], cook: Int? = nil) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: "Dish", tags: tags, prepSteps: prep)
        meal.cookMinutes = cook
        return meal
    }

    private func badges(_ meal: LibraryMeal, start: StartCooking?) -> [DayCardModel.Badge] {
        NightBadges.badges(meal: meal, library: [meal], allergies: [], home: [], lookup: .loaded, start: start,
                           locale: enUS)
    }

    @Test func prepAndStartAreOneBadgeNotTwo() {
        let dish = meal([PrepStep(step: "Thaw the chicken", leadHours: 24)], cook: 180)
        let result = badges(dish, start: window(start: 15 * 60, dinner: 18 * 60))
        #expect(result.count == 1)
        #expect(plain(result.first.flatMap { if case .prepLine(let line) = $0 { line.text } else { nil } })
            == "Thaw the chicken · 1 day ahead · Cook 3:00 – 6:00 PM")
    }

    @Test func aDishWithNoTimeKeepsOnlyItsPrep() {
        let dish = meal([PrepStep(step: "Thaw the chicken", leadHours: 24)])
        #expect(badges(dish, start: nil) == [.prepLine(PrepLine("Thaw the chicken · 1 day ahead"))])
    }

    @Test func aDishWithNeitherHasNoLine() {
        #expect(badges(meal([]), start: nil).isEmpty)
    }

    @Test func aPassedStartBringsBackJustThePrep() {
        let dish = meal([PrepStep(step: "Thaw the chicken", leadHours: 24)], cook: 180)
        #expect(badges(dish, start: nil) == [.prepLine(PrepLine("Thaw the chicken · 1 day ahead"))])
    }

    @Test func aCookedDishOrQuickPickHasNoLine() {
        let dish = meal([PrepStep(step: "Thaw the chicken", leadHours: 24)], cook: 180)
        let cooked = NightBadges.badges(meal: dish, library: [dish], allergies: [], home: [], lookup: .loaded,
                                        start: window(start: 15 * 60, dinner: 18 * 60), alreadyCooked: true)
        #expect(cooked.isEmpty)
    }

    @Test func theCardGroupsItBesideTheDish() {
        let line = PrepLine("Thaw · Cook 3:00 – 6:00 PM", spoken: "Thaw. Start cooking at 3:00 PM for dinner at 6:00 PM")
        #expect(DayCardText.groupBadges([.prepLine(line)]).prep == [line])
    }
}

extension String {
    /// The locale's time formats use narrow, thin and hair spaces that a test's literal can't spell.
    var spacesPlain: String {
        String(unicodeScalars.map { $0.properties.isWhitespace ? " " : Character($0) })
    }
}
