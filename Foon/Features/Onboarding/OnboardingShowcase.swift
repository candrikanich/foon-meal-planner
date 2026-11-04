import Foundation
import Observation

/// Onboarding's "What Foon does for you" step (docs/spec.md → Onboarding, #236): recipe capture (#59) and tonight
/// rescue (#60), shown with the family's own dinners. It sells what happens, never how: no copy here says AI. A phone
/// that can run the model shows the better way; every other phone shows the plain way, which is the same feature.
/// Nothing is saved and nothing is sent: the recipe is an example post, and the rescue runs on a night that isn't in
/// the plan.
enum OnboardingShowcase {
    enum Variant: Equatable, Sendable {
        /// This phone tidies recipes and words the rescue ideas itself.
        case onThisPhone
        /// A phone that can, still getting ready (the model's downloading): the plain way for now, and this phone
        /// tidies recipes once it's ready.
        case whenReady
        /// The plain way here; a planner's phone that can do more tidies recipes through the household queue.
        case familyCanHelp
    }

    /// The tidy recipe on a phone that can: this phone's own, or the bundled one when it's slow or fails, which
    /// says so, so it never passes for this phone's work.
    enum Tidied: Equatable, Sendable {
        case onThisPhone(StructuredRecipe)
        case bundled(StructuredRecipe)

        var recipe: StructuredRecipe {
            switch self {
            case .onThisPhone(let recipe), .bundled(let recipe): recipe
            }
        }

        var note: String? {
            switch self {
            case .onThisPhone: nil
            case .bundled: OnboardingShowcase.recipeFallback
            }
        }
    }

    /// Long enough for a short recipe on a phone that's warmed up, short enough that the demo never feels stuck.
    static let tidyTimeout: Duration = .seconds(10)
    static let wordingTimeout: Duration = .seconds(6)
    /// The middle choice, so a fresh library's dishes have time to fit.
    static let rescueMinutes = 30

    static func variant(_ availability: AIAvailability) -> Variant {
        switch availability {
        case .available: .onThisPhone
        case .unavailable(.modelNotReady): .whenReady
        case .unavailable: .familyCanHelp
        }
    }

    static func recipeDetail(_ variant: Variant) -> String {
        switch variant {
        case .onThisPhone: recipeOnThisPhone
        case .whenReady: recipeWhenReady
        case .familyCanHelp: recipeFamilyCanHelp
        }
    }

    /// The rescue never uses the queue, so a phone still getting ready gets the every-phone line too.
    static func rescueDetail(_ variant: Variant) -> String {
        variant == .onThisPhone ? rescueOnThisPhone : rescueEveryPhone
    }

    static func continueTitle(tried: Bool) -> String {
        tried ? String(localized: "Got it") : String(localized: "Skip")
    }

    // MARK: - The demo dish

    /// The first dinner they tapped, in the picker's order, that made it into the library. With none tapped (they
    /// skipped, or setup resumed), any dish already there; nil when the library's empty.
    static func demoDish(picked: Set<UUID>, library: [LibraryMeal], catalog: [CatalogDish]) -> LibraryMeal? {
        let usable = library.filter(\.status.isInRotation)
        let order = Dictionary(catalog.map { ($0.id, $0.sortOrder) }, uniquingKeysWith: min)
        let tapped = usable.compactMap { meal -> (order: Int, meal: LibraryMeal)? in
            guard let id = meal.catalogMealID, picked.contains(id) else { return nil }
            return (order[id] ?? .max, meal)
        }
        return tapped.min { ($0.order, $0.meal.name) < ($1.order, $1.meal.name) }?.meal
            ?? usable.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Recipe capture

    /// The example post for a dish, what a plain read makes of it, and the tidy recipe it should become.
    static func recipe(for dish: LibraryMeal?) -> RecipeDemo {
        let name = dish?.name ?? String(localized: "Weeknight chili",
                                        comment: "Onboarding: the example recipe when the family has no dinners yet")
        let lines: [(quantity: String?, name: String)] = dish.map { meal in
            meal.ingredients.sorted { $0.position < $1.position }.map { ($0.quantityText, $0.name) }
        } ?? exampleIngredients
        let ingredients = lines.map { [$0.quantity, $0.name].compactMap { $0 }.joined(separator: " ") }
        let steps = exampleSteps
        let post = examplePost(name: name, ingredients: ingredients, steps: steps)
        let plain = RecipeTextParser.parseCaption(post) ?? RecipeTextParser.Capture()
        let tidied = StructuredRecipe(name: name, servings: dish?.servings, ingredients: ingredients, steps: steps,
                                      prepSteps: [])
        return RecipeDemo(post: post, plain: plain, tidied: tidied)
    }

    /// On a phone that can, the real tidy-up over the plain read's lines (only those, as #59 sends), and the bundled
    /// tidy recipe if it's slow or fails. Nil on any other phone: the plain read is what lands there.
    static func tidy(_ demo: RecipeDemo, ai: AIService, timeout: Duration = tidyTimeout) async -> Tidied? {
        guard ai.canRun else { return nil }
        guard let payload = RecipeJobPayload(demo.plain) else { return .bundled(demo.tidied) }
        var quick = ai
        quick.timeout = timeout
        if case .done(let recipe) = await RecipeStructuring.structure(payload, quick) { return .onThisPhone(recipe) }
        return .bundled(demo.tidied)
    }

    private static let exampleIngredients: [(quantity: String?, name: String)] = [
        ("1 lb", "ground beef"), ("1 can", "kidney beans"), ("1 can", "diced tomatoes"), ("1", "onion"),
        ("2 tbsp", "chili powder")
    ]

    private static var exampleSteps: [String] {
        [
            String(localized: "Get everything out and ready.", comment: "Onboarding: example recipe step 1"),
            String(localized: "Cook it the way your family likes it.", comment: "Onboarding: example recipe step 2"),
            String(localized: "Serve it hot.", comment: "Onboarding: example recipe step 3")
        ]
    }

    /// A social post as it's shared: the page's counts, a shouted title, emoji, an ask and hashtags around the
    /// recipe. The headers and the noise stay English, since that's what the plain read knows to look for.
    private static func examplePost(name: String, ingredients: [String], steps: [String]) -> String {
        let title = String(localized: "Our family's favorite \(name)",
                           comment: "Onboarding: the example post's title, shouted in capitals; the dish's name")
        let keycaps = ["1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣"]
        let shouted = title.uppercased(with: .current)
        return (["1,284 likes, 96 comments - a_home_cook on October 12, 2026: \"\(shouted) 😍🔥", "Ingredients:"]
            + ingredients.map { "- \($0)" }
            + ["Directions:"]
            + zip(keycaps, steps).map { "\($0) \($1)" }
            + ["Comment RECIPE and I'll send it to you 💌", "#dinner #familydinner #easyrecipes\""])
            .joined(separator: "\n")
    }

    // MARK: - Tonight rescue

    /// The real rescue over the family's library, on a made-up tonight with everyone home. The night isn't in any
    /// week, so choosing nothing here changes nothing.
    static func rescueIdeas(library: [LibraryMeal], allergies: [MemberAllergies], settings: HouseholdSettings,
                            today: CalendarDay, seed: UInt64) -> [TonightRescue.Idea] {
        let night = WeekNight(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x36)), date: today,
                              effort: .normal, dinnerTime: settings.dinnerTime, mealID: nil, mealName: nil,
                              quickPick: nil, locked: false, attendance: [:])
        let planning = PlanningInputs(nights: [PlanningNight(night)], meals: library, settings: settings,
                                      today: today)
        return TonightRescue.ideas(minutes: rescueMinutes, nightID: night.id, week: [night], planning: planning,
                                   freezer: [], logs: [], stock: [:], allergies: allergies, seed: seed)
    }

    /// The friendly lines, by idea id, through the same prompt as the rescue sheet (no names, allergies or who's
    /// home). None on a phone that can't, or when it's slow.
    static func wording(_ ideas: [TonightRescue.Idea], ai: AIService,
                        timeout: Duration = wordingTimeout) async -> [String: String] {
        guard ai.canRun, !ideas.isEmpty else { return [:] }
        var quick = ai
        quick.timeout = timeout
        return await RescueWording.word(ideas, language: Locale.current.language, quick)
    }

    // MARK: - Copy

    static var title: String { String(localized: "What Foon does for you") }
    static var intro: String {
        String(localized: "Two ways Foon takes work off your plate, with your own dinners. Try one, or skip ahead.")
    }

    static var recipeTitle: String { String(localized: "Share any recipe") }
    static var recipeBody: String {
        String(localized: "Share a recipe from any app, a photo or a PDF, and it lands in your ideas.")
    }
    static var recipeOnThisPhone: String {
        String(localized: "This phone tidies it up as it lands: the name, the amounts and the steps.")
    }
    static var recipeFamilyCanHelp: String {
        String(localized: """
            It lands just as it was shared. When a planner in your family has a phone that can do more, it tidies \
            the recipe up for you.
            """)
    }
    static var recipeWhenReady: String {
        String(localized: "For now it lands just as it was shared. Once this phone is ready, it tidies recipes up too.")
    }
    static var recipeShared: String { String(localized: "What you shared") }
    static var recipeLands: String { String(localized: "What lands in your ideas") }
    static var recipeTidying: String { String(localized: "Tidying it up on this phone…") }
    static var recipeFallback: String { String(localized: "Here's how it'll look once it's tidied.") }
    static var recipeExample: String { String(localized: "An example post. Nothing is saved.") }

    static var rescueTitle: String { String(localized: "Tonight's a mess? Foon has a plan.") }
    static var rescueBody: String {
        String(localized: "Tap What can we make? on tonight's card for three ideas from what's already in the house.")
    }
    static var rescueOnThisPhone: String {
        String(localized: "On this phone, each idea comes with a friendly word about the food.")
    }
    static var rescueEveryPhone: String {
        String(localized: "The ideas come from your own dinners, so they work on every phone.")
    }
    static var rescueExample: String { String(localized: "From your dinners, for tonight. Your plan stays as it is.") }

    static var showMe: String { String(localized: "Show me") }

    /// Everything the step can say, for the test that keeps "AI" out of it.
    static var allCopy: [String] {
        [title, intro, recipeTitle, recipeBody, recipeOnThisPhone, recipeWhenReady, recipeFamilyCanHelp, recipeShared,
         recipeLands, recipeTidying, recipeFallback, recipeExample, rescueTitle, rescueBody, rescueOnThisPhone,
         rescueEveryPhone, rescueExample, showMe, continueTitle(tried: false), continueTitle(tried: true)]
    }
}

/// An example shared recipe: the post as it arrives, the plain read of it (what lands on any phone) and the tidy
/// recipe it becomes.
struct RecipeDemo: Equatable, Sendable {
    let post: String
    let plain: RecipeTextParser.Capture
    let tidied: StructuredRecipe
}

/// The step's state. Built from values, never a store or a client, so trying either card can't save or send
/// anything.
@MainActor @Observable
final class ShowcaseModel {
    let variant: OnboardingShowcase.Variant
    let dishName: String?
    let recipe: RecipeDemo
    private(set) var recipeShown = false
    private(set) var isTidying = false
    /// The tidy recipe on a phone that can, once it's back. Nil means the plain read is what shows.
    private(set) var tidyResult: OnboardingShowcase.Tidied?
    /// Nil until the rescue card's tried.
    private(set) var rescue: [TonightRescue.Idea]?
    private(set) var wording: [String: String] = [:]

    private let library: [LibraryMeal]
    private let allergies: [MemberAllergies]
    private let settings: HouseholdSettings
    private let today: CalendarDay
    private let ai: AIService
    private let seed: UInt64

    var tried: Bool { recipeShown || rescue != nil }
    var tidied: StructuredRecipe? { tidyResult?.recipe }
    /// Set when the bundled recipe stands in for this phone's, so it's never taken for this phone's work.
    var tidyNote: String? { tidyResult?.note }

    init(dish: LibraryMeal?, library: [LibraryMeal], allergies: [MemberAllergies], settings: HouseholdSettings,
         today: CalendarDay, ai: AIService, seed: UInt64 = .random(in: .min ... .max)) {
        variant = OnboardingShowcase.variant(ai.availability())
        dishName = dish?.name
        recipe = OnboardingShowcase.recipe(for: dish)
        (self.library, self.allergies, self.settings) = (library, allergies, settings)
        (self.today, self.ai, self.seed) = (today, ai, seed)
    }

    func showRecipe() async {
        guard !recipeShown else { return }
        recipeShown = true
        guard variant == .onThisPhone else { return }
        isTidying = true
        tidyResult = await OnboardingShowcase.tidy(recipe, ai: ai)
        isTidying = false
    }

    func showRescue() async {
        guard rescue == nil else { return }
        let ideas = OnboardingShowcase.rescueIdeas(library: library, allergies: allergies, settings: settings,
                                                   today: today, seed: seed)
        rescue = ideas
        wording = await OnboardingShowcase.wording(ideas, ai: ai)
    }
}
