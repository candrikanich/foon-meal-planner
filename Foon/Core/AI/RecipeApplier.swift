import Foundation

/// A meal as the server has it right now, with the version a conditional save checks.
struct FreshMeal: Equatable, Sendable {
    let meal: LibraryMeal
    /// `meals.updated_at` exactly as the server wrote it.
    let version: String
}

/// Why a conditional save didn't go through, when it's the server saying no rather than the network failing.
enum RecipeSaveError: Error, Equatable {
    /// Saved by someone else since it was read.
    case changed
    /// Not allowed, or the meal's gone.
    case refused
}

/// Puts a finished AI recipe into the meal it was for, never over an edit (docs/spec.md → Household AI queue). It reads the
/// meal fresh from the server, merges, and saves only if nobody has saved it since that read; if someone has, it reads and
/// merges again, so their edit wins.
struct RecipeApplier: Sendable {
    var fetch: @Sendable (_ mealID: UUID) async throws -> FreshMeal?
    var save: @Sendable (_ mealID: UUID, _ meal: MealDraft.Saved, _ version: String) async throws -> Void

    /// Tries this many reads before giving up on a meal that keeps changing under it.
    static let attempts = 3

    func apply(_ recipe: StructuredRecipe, for watch: RecipeWatch) async -> AIQueueStore.ApplyOutcome {
        for _ in 0..<Self.attempts {
            let fresh: FreshMeal?
            do {
                fresh = try await fetch(watch.mealID)
            } catch {
                return .retry
            }
            // Gone, or nothing nobody's touched is left to change.
            guard let fresh,
                  let merged = RecipeMerge.merged(MealDraft(fresh.meal), baseline: watch.baseline, recipe: recipe),
                  let saved = try? merged.validated() else { return .finished }
            do {
                try await save(watch.mealID, saved, fresh.version)
                return .applied
            } catch RecipeSaveError.changed {
                continue
            } catch RecipeSaveError.refused {
                return .finished
            } catch {
                return .retry
            }
        }
        return .finished
    }
}

extension RecipeApplier {
    static func live(_ client: LibraryClient) -> RecipeApplier {
        RecipeApplier(fetch: client.freshMeal, save: client.saveIfUnchanged)
    }
}
