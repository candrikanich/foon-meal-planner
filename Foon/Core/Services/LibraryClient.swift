import Foundation
import Supabase

/// One allergy row from `member_allergies`: a standard allergen, or Other with the guardian's text.
struct AllergyRow: Decodable, Equatable, Sendable {
    let memberID: UUID
    let allergen: Allergen
    let customText: String?

    private enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case allergen = "category"
        case customText = "custom_text"
    }
}

enum LibraryClientError: Error {
    /// The server changed nothing: the meal is gone or this person may no longer change it.
    case notAllowed
}

/// The household's library, the shared catalog, and what the library screen shows alongside them.
/// Row-level security decides who may change what; only planners archive or add dishes.
struct LibraryClient: Sendable {
    var meals: @Sendable (_ householdID: UUID) async throws -> [LibraryMeal]
    var history: @Sendable (_ householdID: UUID) async throws -> [MealHistory]
    var catalog: @Sendable () async throws -> [CatalogDish]
    var allergies: @Sendable (_ householdID: UUID) async throws -> [AllergyRow]
    var setStatus: @Sendable (_ mealID: UUID, _ status: MealStatus) async throws -> Void
    /// Copies a starter dish into the library (or returns the copy already there) and returns its id.
    var addFromCatalog: @Sendable (_ householdID: UUID, _ dishID: UUID) async throws -> UUID
    var photoURL: @Sendable (_ path: String) async throws -> URL
    /// Saves the meal's fields and replaces its ingredient lines in one transaction.
    var save: @Sendable (_ mealID: UUID, _ meal: MealDraft.Saved) async throws -> Void
    /// Copy and tweak: returns the new meal's id.
    var copy: @Sendable (_ mealID: UUID, _ name: String) async throws -> UUID
    /// Quick add: creates a meal with its ingredient lines and returns its id.
    var create: @Sendable (_ householdID: UUID, _ meal: MealDraft.Saved) async throws -> UUID
    /// Every item the household has used (meals and lists), for autocomplete.
    var itemNames: @Sendable (_ householdID: UUID) async throws -> [String]
    /// Uploads a prepared JPEG and points the meal at it.
    var setPhoto: @Sendable (_ meal: LibraryMeal, _ preparedJPEG: Data) async throws -> Void
    /// Each member's current verdict on each dish, and how often each was liked: what reactions feed planning.
    var verdicts: @Sendable (_ householdID: UUID) async throws -> [MealVerdict] = { _ in [] }
    var likes: @Sendable (_ householdID: UUID) async throws -> [MealLikes] = { _ in [] }
    var servingNotes: @Sendable (_ householdID: UUID) async throws -> [ServingNote] = { _ in [] }
    /// Sets, changes, or (with a blank note) clears a member's serving note on a dish.
    var setServingNote: @Sendable (_ mealID: UUID, _ memberID: UUID, _ note: String) async throws -> Void = { _, _, _ in }
    /// Reads a recipe link through the import-recipe Edge Function. Throws `RecipeImportError`.
    var importRecipe: @Sendable (_ link: String) async throws -> RecipeImport = { _ in throw RecipeImportError.unavailable }
}

enum RecipeImportError: Error, Equatable {
    /// Not a web link the server will open (private networks, other schemes).
    case notAllowed
    /// The page couldn't be reached or read.
    case unavailable

    init(status: Int?) {
        self = status == 400 ? .notAllowed : .unavailable
    }
}

extension LibraryClient {
    static func live(_ client: SupabaseClient) -> LibraryClient {
        let photos = PhotoStorageClient.live(client)
        return LibraryClient(
            meals: { householdID in
                let rows: [MealRow] = try await client.from("meals")
                    .select("""
                        id, household_id, catalog_meal_id, name, servings, tags, status, photo_path, made_by_member_id, \
                        created_at, steps, source_url, prep_steps, cook_minutes, \
                        meal_ingredients(item_id, position, quantity_text, items(canonical_name, category, note, keep_on_hand)), \
                        meal_sides!meal_sides_meal_fkey(position, side_meal_id, item_id, items(canonical_name))
                        """)
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
                return rows.map(\.meal)
            },
            history: { householdID in
                try await client.from("meal_history")
                    .select("meal_id, times_made, last_made")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            catalog: {
                let rows: [CatalogRow] = try await client.from("catalog_meals")
                    .select("id, name, category, tags, popular, sort_order, catalog_ingredients(name, position)")
                    .order("sort_order")
                    .execute()
                    .value
                return rows.map(\.dish)
            },
            allergies: { householdID in
                try await client.from("member_allergies")
                    .select("member_id, category, custom_text")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            setStatus: { mealID, status in
                // Row-level security turns a refused update into zero rows, not an error, so check.
                let updated: [AddedMeal] = try await client.from("meals")
                    .update(["status": status.rawValue])
                    .eq("id", value: mealID)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            },
            addFromCatalog: { householdID, dishID in
                let meal: AddedMeal = try await client.rpc(
                    "add_catalog_meal", params: ["target_household": householdID, "catalog_meal": dishID]
                )
                .execute()
                .value
                return meal.id
            },
            photoURL: photos.signedURL,
            save: { mealID, meal in
                try await client.rpc("save_meal", params: SaveMealParams(mealID: mealID, meal: meal)).execute()
            },
            copy: { mealID, name in
                let meal: AddedMeal = try await client.rpc(
                    "copy_meal", params: ["source_meal": mealID.uuidString, "copy_name": name]
                )
                .execute()
                .value
                return meal.id
            },
            create: { householdID, meal in
                let created: AddedMeal = try await client.rpc(
                    "create_meal", params: CreateMealParams(householdID: householdID, meal: meal)
                )
                .execute()
                .value
                return created.id
            },
            itemNames: { householdID in
                let rows: [ItemName] = try await client.from("items")
                    .select("canonical_name")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
                return rows.map(\.canonicalName)
            },
            setPhoto: { meal, preparedJPEG in
                let path = try await photos.upload(meal.householdID, preparedJPEG)
                let updated: [AddedMeal] = try await client.from("meals")
                    .update(["photo_path": path])
                    .eq("id", value: meal.id)
                    .select("id")
                    .execute()
                    .value
                guard !updated.isEmpty else { throw LibraryClientError.notAllowed }
            },
            verdicts: { householdID in
                try await client.from("meal_verdicts")
                    .select("meal_id, member_id, reaction, reacted_on")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            likes: { householdID in
                try await client.from("meal_likes")
                    .select("meal_id, likes")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            servingNotes: { householdID in
                try await client.from("serving_notes")
                    .select("meal_id, member_id, note")
                    .eq("household_id", value: householdID)
                    .execute()
                    .value
            },
            setServingNote: { mealID, memberID, note in
                try await client.rpc("set_serving_note", params: [
                    "target_meal": mealID.uuidString, "target_member": memberID.uuidString, "note_text": note
                ]).execute()
            },
            importRecipe: { link in
                do {
                    return try await client.functions.invoke(
                        "import-recipe", options: FunctionInvokeOptions(body: ["url": link])
                    )
                } catch FunctionsError.httpError(let code, _) {
                    throw RecipeImportError(status: code)
                } catch {
                    throw RecipeImportError.unavailable
                }
            }
        )
    }
}

private struct MealRow: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let canonicalName: String
            let category: ItemCategory
            let note: String?
            let keepOnHand: Bool

            enum CodingKeys: String, CodingKey {
                case category, note
                case canonicalName = "canonical_name"
                case keepOnHand = "keep_on_hand"
            }
        }

        let itemID: UUID
        let position: Int
        let quantityText: String?
        let items: Item

        enum CodingKeys: String, CodingKey {
            case position, items
            case itemID = "item_id"
            case quantityText = "quantity_text"
        }
    }

    let id: UUID
    let householdID: UUID
    let catalogMealID: UUID?
    let name: String
    let servings: Int
    let tags: [MealTag]
    let status: MealStatus
    let photoPath: String?
    let madeByMemberID: UUID?
    let createdAt: Date
    let steps: [String]
    let sourceURL: String?
    let prepSteps: [PrepStep]
    let cookMinutes: Int?
    let mealIngredients: [Line]
    let mealSides: [Side]

    struct Side: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let canonicalName: String

            enum CodingKeys: String, CodingKey { case canonicalName = "canonical_name" }
        }

        let position: Int
        let sideMealID: UUID?
        let itemID: UUID?
        let items: Item?

        enum CodingKeys: String, CodingKey {
            case position, items
            case sideMealID = "side_meal_id"
            case itemID = "item_id"
        }

        var side: MealSide? {
            if let sideMealID { return .meal(sideMealID) }
            if let itemID, let items { return .item(itemID: itemID, name: items.canonicalName) }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, servings, tags, status
        case householdID = "household_id"
        case catalogMealID = "catalog_meal_id"
        case photoPath = "photo_path"
        case madeByMemberID = "made_by_member_id"
        case createdAt = "created_at"
        case steps
        case sourceURL = "source_url"
        case prepSteps = "prep_steps"
        case cookMinutes = "cook_minutes"
        case mealIngredients = "meal_ingredients"
        case mealSides = "meal_sides"
    }

    var meal: LibraryMeal {
        LibraryMeal(
            id: id, householdID: householdID, catalogMealID: catalogMealID, name: name, servings: servings, tags: tags,
            status: status, photoPath: photoPath, madeByMemberID: madeByMemberID, createdAt: createdAt,
            ingredients: mealIngredients.sorted { $0.position < $1.position }.map {
                MealIngredient(itemID: $0.itemID, name: $0.items.canonicalName, quantityText: $0.quantityText,
                               position: $0.position, note: $0.items.note, category: $0.items.category,
                               keepOnHand: $0.items.keepOnHand)
            },
            steps: steps, sourceURL: sourceURL.flatMap(URL.init(string:)), prepSteps: prepSteps,
            sides: mealSides.sorted { $0.position < $1.position }.compactMap(\.side),
            cookMinutes: cookMinutes
        )
    }
}

private struct CatalogRow: Decodable, Sendable {
    struct Ingredient: Decodable, Sendable {
        let name: String
        let position: Int
    }

    let id: UUID
    let name: String
    let category: String
    let tags: [MealTag]
    let popular: Bool
    let sortOrder: Int
    let catalogIngredients: [Ingredient]

    enum CodingKeys: String, CodingKey {
        case id, name, category, tags, popular
        case sortOrder = "sort_order"
        case catalogIngredients = "catalog_ingredients"
    }

    var dish: CatalogDish {
        CatalogDish(id: id, name: name, category: category, tags: tags, popular: popular, sortOrder: sortOrder,
                    ingredients: catalogIngredients.sorted { $0.position < $1.position }.map(\.name))
    }
}

private struct SaveMealParams: Encodable, Sendable {
    let mealID: UUID
    let meal: MealDraft.Saved

    enum CodingKeys: String, CodingKey {
        case mealID = "target_meal"
        case name = "meal_name"
        case servings = "meal_servings"
        case tags = "meal_tags"
        case steps = "meal_steps"
        case sourceURL = "meal_source_url"
        case madeBy = "made_by"
        case lines
        case sides
        case cookMinutes = "meal_cook_minutes"
    }

    // Every argument is sent, nulls included: PostgREST matches functions by argument names.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mealID, forKey: .mealID)
        // Always sent from this build, so removing every side reaches the database. create_meal has no sides yet.
        try container.encode(meal.sides, forKey: .sides)
        // Null means "leave it" to save_meal, for older builds; 0 is how this one clears it.
        try container.encode(meal.cookMinutes ?? 0, forKey: .cookMinutes)
        try Self.encodeFields(of: meal, to: encoder)
    }

    static func encodeFields(of meal: MealDraft.Saved, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meal.name, forKey: .name)
        try container.encode(meal.servings, forKey: .servings)
        try container.encode(meal.tags, forKey: .tags)
        try container.encode(meal.steps, forKey: .steps)
        try container.encode(meal.sourceURL?.absoluteString, forKey: .sourceURL)
        try container.encode(meal.madeByMemberID, forKey: .madeBy)
        try container.encode(meal.lines, forKey: .lines)
    }
}

private struct CreateMealParams: Encodable, Sendable {
    let householdID: UUID
    let meal: MealDraft.Saved

    private enum CodingKeys: String, CodingKey {
        case householdID = "target_household"
    }

    /// The same arguments as save_meal, with the household in place of the meal.
    func encode(to encoder: Encoder) throws {
        try SaveMealParams.encodeFields(of: meal, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdID, forKey: .householdID)
    }
}

private struct ItemName: Decodable, Sendable {
    let canonicalName: String

    enum CodingKeys: String, CodingKey { case canonicalName = "canonical_name" }
}

private struct AddedMeal: Decodable, Sendable {
    let id: UUID
}
