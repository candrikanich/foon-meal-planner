import Foundation
import Testing
@testable import Foon

struct PrepSuggestionsTests {
    private func kinds(name: String = "Dinner", ingredients: [String] = [], steps: String = "", tags: Set<MealTag> = [],
                       existing: [String] = [], keepsMeatFrozen: Bool = true) -> [PrepKind] {
        PrepSuggestions.suggestions(name: name, ingredients: ingredients, steps: steps, tags: tags, existing: existing,
                                    keepsMeatFrozen: keepsMeatFrozen).map { PrepKind(step: $0.step) }
    }

    @Test func meatSuggestsAThaw() {
        #expect(kinds(ingredients: ["ground beef", "taco shells"]) == [.thaw])
        #expect(kinds(name: "Pot roast") == [.thaw])
        #expect(kinds(name: "Cheese pizza", ingredients: ["dough", "cheese"]).isEmpty)
    }

    @Test func aThawTagOrRecipeStepSuggestsOneForAnythingElse() {
        #expect(kinds(name: "Shrimp boil", tags: [.thawFirst]) == [.thaw])
        #expect(kinds(name: "Shrimp boil", steps: "Defrost the shrimp overnight") == [.thaw])
    }

    @Test func aHouseholdThatBuysFreshIsntOfferedAThaw() {
        #expect(kinds(ingredients: ["ground beef"], tags: [.thawFirst], keepsMeatFrozen: false).isEmpty)
    }

    @Test func marinatingAndSlowCookersAreSpotted() {
        #expect(kinds(name: "Tofu bowl", steps: "Marinate the tofu") == [.marinate])
        #expect(kinds(name: "Tofu bowl", ingredients: ["teriyaki marinade"]) == [.marinate])
        #expect(kinds(name: "Bean soup", tags: [.slowCooker]) == [.slowCooker])
        #expect(kinds(name: "Crock pot beans") == [.slowCooker])
        #expect(kinds(name: "Bean soup", steps: "Put it all in the slow cooker") == [.slowCooker])
    }

    @Test func aKindTheDishHasIsntOfferedAgain() {
        #expect(kinds(ingredients: ["chicken"], steps: "Marinate", existing: ["Thaw the chicken"]) == [.marinate])
        #expect(kinds(name: "Tofu", steps: "Marinate", existing: ["Marinate it overnight"]).isEmpty)
    }

    @Test func suggestionsCarryTheUsualLeadTimes() {
        let found = PrepSuggestions.suggestions(name: "Slow cooker beef", ingredients: [], steps: "Marinate", tags: [], existing: [],
                                                keepsMeatFrozen: true)
        #expect(found.map(\.leadHours) == [24, 4, 8])
    }

    @Test func aMarinateInTheRecipeDoesntHideTheSlowCooker() {
        let found = PrepSuggestions.suggestions(name: "Stew", ingredients: [], steps: "Marinate it. Put it in the slow cooker.", tags: [],
                                                existing: [], keepsMeatFrozen: true)
        #expect(found.contains { $0.leadHours == 8 })
    }

    @Test func aStepAboutTheMarinadeCountsAsMarinating() {
        let found = PrepSuggestions.suggestions(name: "Stew", ingredients: [], steps: "Make the marinade", tags: [],
                                                existing: ["Make the marinade"], keepsMeatFrozen: true)
        #expect(found.isEmpty)
        #expect(PrepKind(step: "Make the marinade") == .marinate)
    }
}

@Suite struct LenientPrepStepsTests {
    private func decode(_ json: String) throws -> [PrepStep] {
        try JSONDecoder().decode(LenientPrepSteps.self, from: Data(json.utf8)).steps
    }

    @Test func aStepThatWontReadDoesntCostTheOthers() throws {
        let steps = try decode(#"[{"step": 1}, {"step": "Soak", "lead_hours": 1.5}, {"step": "Marinate", "lead_hours": 4}, 7]"#)
        #expect(steps == [PrepStep(step: "Marinate", leadHours: 4)])
    }

    @Test func notAListReadsAsNoSteps() throws {
        #expect(try decode(#"{"step": "Soak"}"#).isEmpty)
    }
}
