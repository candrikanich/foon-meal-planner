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
}

extension LibraryClient {
    static func live(_ client: SupabaseClient) -> LibraryClient {
        let photos = PhotoStorageClient.live(client)
        return LibraryClient(
            meals: { householdID in
                let rows: [MealRow] = try await client.from("meals")
                    .select("""
                        id, household_id, catalog_meal_id, name, servings, tags, status, photo_path, made_by_member_id, \
                        created_at, meal_ingredients(position, quantity_text, items(canonical_name))
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
            photoURL: photos.signedURL
        )
    }
}

private struct MealRow: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let canonicalName: String

            enum CodingKeys: String, CodingKey { case canonicalName = "canonical_name" }
        }

        let position: Int
        let quantityText: String?
        let items: Item

        enum CodingKeys: String, CodingKey {
            case position, items
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
    let mealIngredients: [Line]

    enum CodingKeys: String, CodingKey {
        case id, name, servings, tags, status
        case householdID = "household_id"
        case catalogMealID = "catalog_meal_id"
        case photoPath = "photo_path"
        case madeByMemberID = "made_by_member_id"
        case createdAt = "created_at"
        case mealIngredients = "meal_ingredients"
    }

    var meal: LibraryMeal {
        LibraryMeal(
            id: id, householdID: householdID, catalogMealID: catalogMealID, name: name, servings: servings, tags: tags,
            status: status, photoPath: photoPath, madeByMemberID: madeByMemberID, createdAt: createdAt,
            ingredients: mealIngredients.sorted { $0.position < $1.position }.map {
                MealIngredient(name: $0.items.canonicalName, quantityText: $0.quantityText, position: $0.position)
            }
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

private struct AddedMeal: Decodable, Sendable {
    let id: UUID
}
