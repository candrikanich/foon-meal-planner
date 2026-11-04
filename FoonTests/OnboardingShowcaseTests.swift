import Foundation
import FoundationModels
import Testing
@testable import Foon

/// Onboarding's "What Foon does for you" step (#236): recipe capture (#59) and tonight rescue (#60) shown with the
/// family's own dishes, the better way on a phone that can do it and the plain way everywhere else. The model is
/// stubbed: CI and the simulator usually lack Apple Intelligence.
@MainActor
struct OnboardingShowcaseTests {
    private static let today = CalendarDay(year: 2026, month: 11, day: 4)

    private static func meal(_ name: String, catalogID: UUID? = nil, status: MealStatus = .active,
                             tags: [MealTag] = [.quick], lines: [(String?, String)]) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: name, tags: tags, status: status, catalogMealID: catalogID)
        meal.ingredients = lines.enumerated().map { index, line in
            MealIngredient(itemID: UUID(), name: line.1, quantityText: line.0, position: index + 1)
        }
        return meal
    }

    private static let tacosDish = CatalogDish.fixture(name: "Tacos", sortOrder: 8)
    private static let chiliDish = CatalogDish.fixture(name: "Chili", sortOrder: 20)
    private static let ziti = CatalogDish.fixture(name: "Baked ziti", sortOrder: 4)
    private static let catalog = [tacosDish, chiliDish, ziti]

    private static let tacos = meal("Tacos", catalogID: tacosDish.id, lines: [
        ("1 lb", "ground beef"), ("8", "taco shells"), ("1 cup", "cheddar cheese"), (nil, "salsa")
    ])
    private static let chili = meal("Chili", catalogID: chiliDish.id, lines: [
        ("2 lb", "ground beef"), ("2 cans", "kidney beans"), ("1", "onion")
    ])
    private static let ownDish = meal("Grandma's soup", lines: [("1", "chicken"), ("2", "carrots")])

    private func ai(timeout: Duration = .seconds(5),
                    respond: @escaping @Sendable (String, String, GenerationSchema) async throws -> GeneratedContent)
        -> AIService {
        AIService(availability: { .available }, respond: respond, timeout: timeout)
    }

    // MARK: Which version shows

    @Test func aPhoneThatCanRunItShowsTheBetterWayAndEveryOtherShowsThePlainWay() {
        #expect(OnboardingShowcase.variant(.available) == .onThisPhone)
        let reasons: [AIAvailability.Reason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
                                                 .other]
        for reason in reasons {
            #expect(OnboardingShowcase.variant(.unavailable(reason)) == .familyCanHelp)
        }
    }

    @Test func theButtonSaysSkipUntilACardIsTried() {
        #expect(OnboardingShowcase.continueTitle(tried: false) == String(localized: "Skip"))
        #expect(OnboardingShowcase.continueTitle(tried: true) == String(localized: "Got it"))
    }

    @Test func theCopyNeverSaysAI() {
        let banned = ["AI", "Apple Intelligence", "model", "machine learning", "artificial"]
        for text in OnboardingShowcase.allCopy {
            for word in banned {
                #expect(text.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                        "\(text) says \(word)")
            }
        }
    }

    // MARK: The demo dish

    @Test func theDemoDishIsTheFirstTappedDinnerInPickerOrder() {
        let library = [Self.chili, Self.tacos, Self.ownDish]
        let dish = OnboardingShowcase.demoDish(picked: [Self.chiliDish.id, Self.tacosDish.id], library: library,
                                               catalog: Self.catalog)
        #expect(dish?.id == Self.tacos.id)
    }

    @Test func aTappedDinnerThatDidNotReachTheLibraryIsPassedOver() {
        let dish = OnboardingShowcase.demoDish(picked: [Self.ziti.id, Self.chiliDish.id], library: [Self.chili],
                                               catalog: Self.catalog)
        #expect(dish?.id == Self.chili.id)
    }

    @Test func withNothingTappedTheDemoUsesADishAlreadyInTheLibrary() {
        let archived = Self.meal("Tuna casserole", status: .archived, lines: [("1", "tuna"), ("1", "noodles")])
        let dish = OnboardingShowcase.demoDish(picked: [], library: [archived, Self.ownDish], catalog: Self.catalog)
        #expect(dish?.id == Self.ownDish.id)
        #expect(OnboardingShowcase.demoDish(picked: [], library: [archived], catalog: Self.catalog) == nil)
        #expect(OnboardingShowcase.demoDish(picked: [], library: [], catalog: Self.catalog) == nil)
    }

    // MARK: Recipe capture

    @Test func theSharedPostIsTheirDishWithTheNoiseOfARealOne() {
        let demo = OnboardingShowcase.recipe(for: Self.tacos)

        #expect(demo.post.contains("Tacos") || demo.post.contains("TACOS"))
        for line in Self.tacos.ingredients { #expect(demo.post.contains(line.name)) }
        #expect(demo.post.contains("#"))
    }

    @Test func thePlainReadFindsTheIngredientsAndLeavesTheNoiseOut() {
        let demo = OnboardingShowcase.recipe(for: Self.tacos)

        #expect(demo.plain.ingredients.map(\.name) == Self.tacos.ingredients.map(\.name))
        #expect(!demo.plain.steps.isEmpty)
        let everything = ([demo.plain.name ?? ""] + demo.plain.steps + demo.plain.ingredients.map(\.name))
            .joined(separator: "\n")
        #expect(!everything.contains("#"))
        #expect(!everything.localizedCaseInsensitiveContains("comments"))
        #expect(!everything.localizedCaseInsensitiveContains("send it to you"))
    }

    @Test func theTidyRecipeIsTheDishAsTheFamilySavedIt() {
        let demo = OnboardingShowcase.recipe(for: Self.tacos)

        #expect(demo.tidied.name == "Tacos")
        #expect(demo.tidied.ingredients == ["1 lb ground beef", "8 taco shells", "1 cup cheddar cheese", "salsa"])
        #expect(!demo.tidied.steps.isEmpty)
        #expect(demo.tidied.prepSteps.isEmpty)
    }

    @Test func withNoDishTheDemoUsesTheBundledExample() {
        let demo = OnboardingShowcase.recipe(for: nil)

        #expect(!demo.tidied.name.isEmpty)
        #expect(demo.plain.ingredients.count >= 2)
        #expect(demo.plain.ingredients.count == demo.tidied.ingredients.count)
    }

    @Test func aPhoneThatCanRunItTidiesTheParsedLinesOnly() async {
        let prompts = Prompts()
        let answer = GeneratedRecipe(name: "Family tacos", servings: 4, ingredients: ["1 lb ground beef"],
                                     steps: ["Cook it."], prepSteps: [])
        let demo = OnboardingShowcase.recipe(for: Self.tacos)

        let tidied = await OnboardingShowcase.tidy(demo, ai: ai { _, prompt, _ in
            await prompts.add(prompt)
            return answer.generatedContent
        })

        #expect(tidied == StructuredRecipe(answer))
        let prompt = await prompts.all.first ?? ""
        #expect(prompt.contains("ground beef"))
        #expect(!prompt.contains("#"))
    }

    @Test func aSlowOrFailedTidyFallsBackToTheBundledOne() async {
        let demo = OnboardingShowcase.recipe(for: Self.tacos)
        let slow = ai { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return GeneratedRecipe(name: "x", servings: 1, ingredients: ["x"], steps: [], prepSteps: [])
                .generatedContent
        }
        let failing = ai { _, _, _ in throw CancellationError() }

        #expect(await OnboardingShowcase.tidy(demo, ai: slow, timeout: .milliseconds(50)) == demo.tidied)
        #expect(await OnboardingShowcase.tidy(demo, ai: failing) == demo.tidied)
    }

    @Test func aPhoneThatCannotRunItShowsThePlainReadAndNeverAsks() async {
        let prompts = Prompts()
        let cannot = AIService(availability: { .unavailable(.deviceNotEligible) }, respond: { _, prompt, _ in
            await prompts.add(prompt)
            throw CancellationError()
        })

        #expect(await OnboardingShowcase.tidy(OnboardingShowcase.recipe(for: Self.tacos), ai: cannot) == nil)
        #expect(await prompts.all.isEmpty)
    }

    // MARK: Tonight rescue

    @Test func theRescueDrawsFromTheFamilysOwnDinners() {
        let ideas = OnboardingShowcase.rescueIdeas(library: [Self.tacos, Self.chili], allergies: [],
                                                   settings: HouseholdSettings(), today: Self.today, seed: 1)

        #expect(ideas.count == 3)
        #expect(ideas.contains { [Self.tacos.name, Self.chili.name].contains($0.title) })
        #expect(ideas == OnboardingShowcase.rescueIdeas(library: [Self.tacos, Self.chili], allergies: [],
                                                        settings: HouseholdSettings(), today: Self.today, seed: 1))
    }

    @Test func anEmptyLibraryStillGetsThreeIdeas() {
        let ideas = OnboardingShowcase.rescueIdeas(library: [], allergies: [], settings: HouseholdSettings(),
                                                   today: Self.today, seed: 1)

        #expect(ideas.count == 3)
        #expect(ideas.allSatisfy { if case .quickPick = $0.kind { true } else { false } })
    }

    @Test func theRescueFlagsAllergiesFromCode() {
        let nora = Member.sampleFamily[3]
        let mac = Self.meal("Mac and cheese", lines: [("1 lb", "elbow macaroni"), ("2 cups", "milk")])
        let ideas = OnboardingShowcase.rescueIdeas(
            library: [mac], allergies: [MemberAllergies(memberID: nora.id, firstName: nora.firstName,
                                                        allergens: [.milk])],
            settings: HouseholdSettings(), today: Self.today, seed: 1)

        #expect(ideas.first { $0.title == mac.name }?.isFlagged == true)
    }

    @Test func friendlyLinesComeOnlyFromAPhoneThatCanRunThemInTime() async {
        let ideas = OnboardingShowcase.rescueIdeas(library: [Self.tacos, Self.chili], allergies: [],
                                                   settings: HouseholdSettings(), today: Self.today, seed: 1)
        let answer = GeneratedRescueWording(lines: ["Crunchy and quick", "Warm and cozy", "Nobody cooks"])
        let prompts = Prompts()
        let quick = ai { _, prompt, _ in
            await prompts.add(prompt)
            return answer.generatedContent
        }
        let slow = ai { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return answer.generatedContent
        }

        let lines = await OnboardingShowcase.wording(ideas, ai: quick)
        #expect(lines.count == 3)
        #expect(lines[ideas[0].id] == "Crunchy and quick")
        #expect(await prompts.all.first == RescueWording.prompt(ideas))
        #expect(await OnboardingShowcase.wording(ideas, ai: slow, timeout: .milliseconds(50)).isEmpty)
        #expect(await OnboardingShowcase.wording(ideas, ai: .none).isEmpty)
    }

    // MARK: The step

    @Test func tryingTheRecipeOnAPhoneThatCanRunItEndsTidied() async {
        let model = ShowcaseModel(dish: Self.tacos, library: [Self.tacos], allergies: [],
                                  settings: HouseholdSettings(), today: Self.today,
                                  ai: ai { _, _, _ in throw CancellationError() })

        #expect(model.variant == .onThisPhone)
        #expect(!model.tried)
        await model.showRecipe()

        #expect(model.tried)
        #expect(model.recipeShown)
        #expect(!model.isTidying)
        #expect(model.tidied == model.recipe.tidied)
    }

    @Test func tryingOnAPhoneThatCannotRunItShowsThePlainWay() async {
        let model = ShowcaseModel(dish: Self.tacos, library: [Self.tacos, Self.chili], allergies: [],
                                  settings: HouseholdSettings(), today: Self.today, ai: .none)

        #expect(model.variant == .familyCanHelp)
        await model.showRecipe()
        await model.showRescue()

        #expect(model.tidied == nil)
        #expect(!model.isTidying)
        #expect(model.rescue?.count == 3)
        #expect(model.wording.isEmpty)
    }
}

private actor Prompts {
    private(set) var all: [String] = []
    func add(_ prompt: String) { all.append(prompt) }
}
