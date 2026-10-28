import Foundation

extension LibraryMeal {
    static func fixture(
        id: UUID = UUID(),
        name: String = "Tacos",
        servings: Int = 4,
        tags: [MealTag] = [],
        status: MealStatus = .active,
        ingredients: [String] = [],
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        catalogMealID: UUID? = nil,
        photoPath: String? = nil,
        madeByMemberID: UUID? = nil,
        steps: [String] = [],
        sourceURL: URL? = nil,
        prepSteps: [PrepStep] = [],
        notes: [String: String] = [:]
    ) -> LibraryMeal {
        LibraryMeal(
            id: id, householdID: Household.sample.id, catalogMealID: catalogMealID, name: name, servings: servings,
            tags: tags, status: status, photoPath: photoPath, madeByMemberID: madeByMemberID, createdAt: createdAt,
            ingredients: ingredients.enumerated().map {
                MealIngredient(itemID: UUID(), name: $1, quantityText: nil, position: $0 + 1, note: notes[$1])
            },
            steps: steps, sourceURL: sourceURL, prepSteps: prepSteps
        )
    }

    /// A small library for previews: a mix of quick, trial, backup, flagged, and archived dishes.
    static let sampleLibrary: [LibraryMeal] = {
        var meals = sampleMeals
        meals[0].sides = [.meal(meals[4].id), .item(itemID: UUID(), name: "chips and salsa")]
        return meals
    }()

    private static let sampleMeals: [LibraryMeal] = [
        .fixture(name: "Tacos", tags: [.quick, .beginner], ingredients: ["ground beef", "taco shells", "cheddar cheese"],
                 madeByMemberID: Member.sampleFamily[1].id,
                 steps: ["Brown the beef with the seasoning.", "Warm the shells.", "Set out the toppings."],
                 sourceURL: URL(string: "https://example.com/tacos")),
        .fixture(name: "Homemade mac and cheese", tags: [.leftovers], ingredients: ["elbow macaroni", "milk", "butter"],
                 createdAt: Date(timeIntervalSince1970: 1_799_000_000),
                 notes: ["milk": "Whole, not skim"]),
        .fixture(name: "Salsa chicken over rice", tags: [.slowCooker], status: .trial,
                 ingredients: ["chicken breasts", "salsa", "rice"], createdAt: Date(timeIntervalSince1970: 1_798_000_000)),
        .fixture(name: "Frozen pizza", tags: [.quick, .backup], ingredients: ["frozen pizza"],
                 createdAt: Date(timeIntervalSince1970: 1_797_000_000)),
        .fixture(name: "Grilled chicken", tags: [.grill, .thawFirst], ingredients: ["chicken thighs"],
                 createdAt: Date(timeIntervalSince1970: 1_796_000_000),
                 prepSteps: [PrepStep(step: "Move the chicken to the fridge to thaw", leadHours: 24)]),
        .fixture(name: "Tuna casserole", status: .archived, ingredients: ["tuna", "egg noodles", "cream of mushroom soup"],
                 createdAt: Date(timeIntervalSince1970: 1_795_000_000))
    ]
}

extension CatalogDish {
    static func fixture(
        id: UUID = UUID(),
        name: String = "Tacos",
        category: String = "Tex-Mex",
        tags: [MealTag] = [],
        popular: Bool = false,
        sortOrder: Int = 0,
        ingredients: [String] = []
    ) -> CatalogDish {
        CatalogDish(id: id, name: name, category: category, tags: tags, popular: popular, sortOrder: sortOrder,
                    ingredients: ingredients)
    }

    static let sampleCatalog: [CatalogDish] = [
        .fixture(name: "Pasta with sauce and meatballs", category: "Pasta", popular: true, sortOrder: 1,
                 ingredients: ["spaghetti", "meatballs", "pasta sauce"]),
        .fixture(name: "Baked ziti", category: "Pasta", tags: [.leftovers], sortOrder: 4,
                 ingredients: ["ziti", "ricotta", "mozzarella"]),
        .fixture(name: "Tacos", category: "Tex-Mex", tags: [.quick], popular: true, sortOrder: 8,
                 ingredients: ["ground beef", "taco shells"]),
        .fixture(name: "Chili", category: "Tex-Mex", tags: [.slowCooker], sortOrder: 13,
                 ingredients: ["ground beef", "kidney beans"]),
        .fixture(name: "Burgers", category: "Grill", tags: [.grill], popular: true, sortOrder: 15,
                 ingredients: ["ground beef", "hamburger buns"])
    ]
}

extension LibraryClient {
    /// Serves the sample library and catalog; Nora (a kid in the sample family) can't have milk.
    static func preview(meals: [LibraryMeal] = LibraryMeal.sampleLibrary) -> LibraryClient {
        LibraryClient(
            meals: { _ in meals },
            history: { _ in
                meals.prefix(1).map {
                    MealHistory(mealID: $0.id, timesMade: 8, lastMade: CalendarDay(year: 2026, month: 10, day: 20))
                }
            },
            catalog: { CatalogDish.sampleCatalog },
            allergies: { _ in [AllergyRow(memberID: Member.sampleFamily[4].id, allergen: .milk, customText: nil)] },
            setStatus: { _, _ in },
            addFromCatalog: { _, _ in UUID() },
            photoURL: { _ in throw URLError(.fileDoesNotExist) },
            save: { _, _ in },
            copy: { _, _ in UUID() },
            create: { _, _ in UUID() },
            itemNames: { _ in ["paper towels", "milk", "bananas"] },
            setPhoto: { _, _ in },
            // Everyone's latest word on the first sample meals, so meal detail's verdicts show in previews.
            verdicts: { _ in
                guard let first = meals.first else { return [] }
                return zip(Member.sampleFamily, [ReactionKind.favorite, .good, .notForMe, .good, .tiredOfIt]).map { member, kind in
                    MealVerdict(mealID: first.id, memberID: member.id, kind: kind,
                                reactedOn: CalendarDay(Date()).adding(days: -2))
                }
            },
            importRecipe: { link in
                RecipeImport(
                    recipe: .init(name: "Weeknight Chili", servings: 4,
                                  ingredients: ["1 lb ground beef", "1 (15 oz) can kidney beans, drained",
                                                "2 tbsp chili powder"],
                                  steps: ["Brown the beef.", "Add everything and simmer 30 minutes."], imageURL: nil),
                    title: "Weeknight Chili", url: URL(string: link) ?? URL(string: "https://example.com")!
                )
            }
        )
    }
}

extension WeekClient {
    /// A week for the sample family, started or not. Owen (away at camp) is out until his return date.
    static func preview(started: Bool = false) -> WeekClient {
        let make: @Sendable (CalendarDay) -> Week = { start in
            Week(planID: UUID(), start: start, approvedAt: nil, nights: (0..<7).map { offset in
                let date = start.adding(days: offset)
                return WeekNight(
                    id: UUID(), date: date, effort: offset == 5 ? .event : .normal, dinnerTime: "18:00",
                    mealID: offset == 2 ? LibraryMeal.sampleLibrary[0].id : nil,
                    mealName: offset == 2 ? LibraryMeal.sampleLibrary[0].name : nil,
                    quickPick: offset == 5 ? .eatOut : nil, locked: offset == 5,
                    attendance: Dictionary(uniqueKeysWithValues: Member.sampleFamily.map { member in
                        (member.id, member.status != .away && !(member.firstName == "Grace" && offset < 3))
                    })
                )
            })
        }
        return WeekClient(
            week: { _, start in started ? make(start) : nil },
            create: { _, start in make(start) },
            setExpected: { _, _, _ in },
            setEffort: { _, _ in },
            setLocked: { _, _ in },
            setNights: { _, _ in },
            setNight: { _, _ in },
            traditions: { _ in [Tradition(weekday: 2, pick: .meal(LibraryMeal.sampleLibrary[0].id), name: "Taco Tuesday")] },
            setTradition: { _, _, _ in }
        )
    }
}
