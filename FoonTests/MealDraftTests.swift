import Foundation
import Testing
@testable import Foon

struct MealDraftTests {
    private let tacos = LibraryMeal(
        id: UUID(), householdID: Household.sample.id, catalogMealID: nil, name: "Tacos", servings: 4,
        tags: [.quick], status: .active, photoPath: nil, madeByMemberID: nil, createdAt: .now,
        ingredients: [MealIngredient(itemID: UUID(), name: "ground beef", quantityText: "1 lb", position: 1),
                      MealIngredient(itemID: UUID(), name: "taco shells", quantityText: nil, position: 2)],
        steps: ["Brown the beef", "Warm the shells"], sourceURL: URL(string: "https://example.com/tacos"),
        prepSteps: []
    )

    @Test func prepStepsRoundTripTrimmedAndWithoutBlanks() throws {
        var meal = tacos
        meal.prepSteps = [PrepStep(step: "Thaw the beef", leadHours: 24)]
        var draft = MealDraft(meal)
        draft.prepLines.append(.init(step: "  Marinate ", leadHours: 4))
        draft.prepLines.append(.init(step: "   ", leadHours: 8))
        draft.prepLines.append(.init(step: "Chop ahead", leadHours: nil))
        #expect(try draft.validated().prepSteps == [PrepStep(step: "Thaw the beef", leadHours: 24), PrepStep(step: "Marinate", leadHours: 4),
                                                    PrepStep(step: "Chop ahead", leadHours: nil)])
    }

    @Test func prepStepLimitsMatchTheServer() {
        var draft = MealDraft(tacos)
        draft.prepLines = (0..<11).map { .init(step: "Step \($0)", leadHours: 1) }
        #expect(throws: MealDraft.Problem.tooManyPrepSteps) { try draft.validated() }
        draft.prepLines = [.init(step: String(repeating: "a", count: 121), leadHours: 1)]
        #expect(throws: MealDraft.Problem.prepStepTooLong) { try draft.validated() }
    }

    @Test func aLeadTheServerWouldRefuseMeansNone() throws {
        var draft = MealDraft(tacos)
        draft.prepLines = [.init(step: "Dry-age", leadHours: 500), .init(step: "Soak", leadHours: 0)]
        #expect(try draft.validated().prepSteps.map(\.leadHours) == [nil, nil])
    }

    @Test func removingEveryPrepStepSendsAnEmptyList() throws {
        var meal = tacos
        meal.prepSteps = [PrepStep(step: "Thaw the beef", leadHours: 24)]
        var draft = MealDraft(meal)
        draft.prepLines = []
        #expect(try draft.validated().prepSteps.isEmpty)
    }

    @Test func aSavedLeadOffTheListStaysOffered() {
        #expect(MealText.leadTimeChoices(including: nil) == [1, 2, 4, 8, 12, 24, 48])
        #expect(MealText.leadTimeChoices(including: 36) == [1, 2, 4, 8, 12, 24, 36, 48])
    }

    @Test func startsFromTheMeal() {
        let draft = MealDraft(tacos)
        #expect(draft.name == "Tacos")
        #expect(draft.servings == 4)
        #expect(draft.tags == [.quick])
        #expect(draft.lines.map(\.name) == ["ground beef", "taco shells"])
        #expect(draft.lines.map(\.quantity) == ["1 lb", ""])
        #expect(draft.stepsText == "Brown the beef\nWarm the shells")
        #expect(draft.link == "https://example.com/tacos")
    }

    @Test func anUnchangedDraftSavesTheSameMeal() throws {
        let saved = try MealDraft(tacos).validated()
        #expect(saved.name == "Tacos")
        #expect(saved.lines == [.init(name: "ground beef", quantity: "1 lb"), .init(name: "taco shells", quantity: nil)])
        #expect(saved.steps == ["Brown the beef", "Warm the shells"])
        #expect(saved.sourceURL == URL(string: "https://example.com/tacos"))
    }

    @Test func pastedIngredientsSplitIntoLines() {
        var draft = MealDraft(tacos)
        draft.addIngredients("1 lb ground beef, taco shells\n2 cups shredded cheese")
        #expect(draft.lines.map(\.name) == ["ground beef", "taco shells", "ground beef", "taco shells", "shredded cheese"])
        #expect(draft.lines.last?.quantity == "2 cups")
    }

    @Test func stepsDropBlankLinesAndTypedNumbering() throws {
        var draft = MealDraft(tacos)
        draft.stepsText = "1. Brown the beef\n\n  2) Add seasoning \n- Warm the shells\nStep 4: Serve"
        #expect(try draft.validated().steps == ["Brown the beef", "Add seasoning", "Warm the shells", "Serve"])
    }

    @Test func blankIngredientLinesAreDropped() throws {
        var draft = MealDraft(tacos)
        draft.lines.append(.init(quantity: "2", name: "   "))
        #expect(try draft.validated().lines.count == 2)
    }

    @Test(arguments: [
        ("example.com/tacos", "https://example.com/tacos"),
        ("  http://example.com  ", "http://example.com"),
        ("", nil)
    ] as [(String, String?)])
    func linksGainASchemeAndBlankMeansNone(typed: String, saved: String?) throws {
        var draft = MealDraft(tacos)
        draft.link = typed
        #expect(try draft.validated().sourceURL?.absoluteString == saved)
    }

    @Test(arguments: [
        ("  ", MealDraft.Problem.nameMissing),
        (String(repeating: "x", count: 81), .nameTooLong)
    ])
    func namesMustFit(name: String, problem: MealDraft.Problem) {
        var draft = MealDraft(tacos)
        draft.name = name
        #expect(throws: problem) { try draft.validated() }
    }

    @Test(arguments: ["javascript:alert(1)", "ftp://example.com/file", "not a link at all", "https://"])
    func onlyWebLinksAreKept(link: String) {
        var draft = MealDraft(tacos)
        draft.link = link
        #expect(throws: MealDraft.Problem.badLink) { try draft.validated() }
    }

    @Test func ingredientsAndQuantitiesMustFit() {
        var longName = MealDraft(tacos)
        longName.lines.append(.init(quantity: "", name: String(repeating: "x", count: 61)))
        #expect(throws: MealDraft.Problem.ingredientTooLong) { try longName.validated() }

        var longQuantity = MealDraft(tacos)
        longQuantity.lines[0].quantity = String(repeating: "1", count: 61)
        #expect(throws: MealDraft.Problem.ingredientTooLong) { try longQuantity.validated() }
    }

    @Test func tooManyStepsIsAProblem() {
        var draft = MealDraft(tacos)
        draft.stepsText = (1...51).map { "Step \($0) thing" }.joined(separator: "\n")
        #expect(throws: MealDraft.Problem.tooManySteps) { try draft.validated() }
    }

    @Test func servingsStayInRange() throws {
        var draft = MealDraft(tacos)
        draft.servings = 0
        #expect(throws: MealDraft.Problem.servings) { try draft.validated() }
        draft.servings = 51
        #expect(throws: MealDraft.Problem.servings) { try draft.validated() }
    }

    /// Postgres counts code points: a family emoji is one character here but five there.
    @Test func lengthsCountLikeTheDatabase() {
        var draft = MealDraft(tacos)
        draft.name = String(repeating: "👨‍👩‍👧", count: 17)
        #expect(throws: MealDraft.Problem.nameTooLong) { try draft.validated() }

        var line = MealDraft(tacos)
        line.lines.append(.init(quantity: "", name: String(repeating: "e\u{301}", count: 31)))
        #expect(throws: MealDraft.Problem.ingredientTooLong) { try line.validated() }
    }

    @Test func aLinkIsMeasuredAsItWillBeStored() {
        var draft = MealDraft(tacos)
        draft.link = "https://example.com/" + String(repeating: "é", count: 700)
        #expect(throws: MealDraft.Problem.badLink) { try draft.validated() }
    }

    @Test func numbersThatStartAStepAreKept() throws {
        var draft = MealDraft(tacos)
        draft.stepsText = "1.5 cups broth go in next\n10:30 start the rice\n2. Serve"
        #expect(try draft.validated().steps == ["1.5 cups broth go in next", "10:30 start the rice", "Serve"])
    }

    @Test func aLongCopyNameIsTrimmedWithoutSplittingCharacters() {
        let copy = MealDraft.copyName(for: String(repeating: "👨‍👩‍👧", count: 20))
        #expect(copy.unicodeScalars.count <= 80)
        #expect(copy.allSatisfy { $0 == "👨‍👩‍👧" })
    }

    @Test func copiesGetAnEditableName() {
        #expect(MealDraft.copyName(for: "Tacos") == "Tacos (copy)")
        #expect(MealDraft.copyName(for: String(repeating: "x", count: 80)).count <= 80)
    }
}

struct MealTextTests {
    @Test func historyReadsNaturally() {
        let calendar = Calendar(identifier: .gregorian)
        #expect(MealText.history(nil, calendar: calendar) == "Not made yet")
        let once = MealHistory(mealID: UUID(), timesMade: 1, lastMade: CalendarDay(year: 2026, month: 10, day: 20))
        #expect(MealText.history(once, calendar: calendar) == "Made once, last on Oct 20")
        let often = MealHistory(mealID: UUID(), timesMade: 8, lastMade: CalendarDay(year: 2026, month: 3, day: 2))
        #expect(MealText.history(often, calendar: calendar) == "Made 8 times, last on Mar 2")
    }

    @Test func prepLeadTimesReadAsHoursOrDays() {
        #expect(MealText.leadTime(hours: 24) == "1 day ahead")
        #expect(MealText.leadTime(hours: 48) == "2 days ahead")
        #expect(MealText.leadTime(hours: 8) == "8 hours ahead")
        #expect(MealText.leadTime(hours: 1) == "1 hour ahead")
        #expect(MealText.leadTime(hours: nil) == nil)
    }

    @Test(arguments: [(MealTag.quick, "Quick"), (.slowCooker, "Slow cooker"), (.thawFirst, "Thaw first"),
                      (.backup, "Backup dinner")])
    func tagsHaveNames(tag: MealTag, name: String) {
        #expect(tag.title == name)
    }
}
