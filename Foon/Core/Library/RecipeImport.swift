import Foundation

/// What the import-recipe Edge Function read from a recipe link. `recipe` is nil when the page has no recipe data;
/// then only the title and link are kept.
struct RecipeImport: Decodable, Equatable, Sendable {
    struct Recipe: Decodable, Equatable, Sendable {
        let name: String
        let servings: Int?
        let ingredients: [String]
        let steps: [String]
        /// Read but not saved (recipe photos belong to their sites); a string so an odd value can't fail the import.
        let imageURL: String?
    }

    let recipe: Recipe?
    let title: String?
    /// Where the page ended up, after redirects.
    let url: URL

    var hasRecipe: Bool { recipe != nil }

    /// A new meal for the library: scaled from the recipe's servings to the household, the link kept as its source.
    func draft(householdSize: Int) -> MealDraft {
        let size = min(max(householdSize, 1), 50)
        var draft = MealDraft(newNamed: Self.clamped(recipe?.name ?? title ?? url.host() ?? url.absoluteString, to: 80))
        draft.link = Self.sourceLink(url)
        guard let recipe else { return draft }
        draft.servings = size
        let factor = recipe.servings.map { Double(size) / Double($0) } ?? 1
        draft.lines = recipe.ingredients.compactMap { text in
            guard let parsed = IngredientParser.parseLine(text) else { return nil }
            let quantity = parsed.quantity.map { QuantityScaler.scale($0, by: factor) } ?? ""
            return MealDraft.Line(quantity: Self.clamped(quantity, to: 60), name: Self.ingredientName(parsed.name))
        }
        draft.stepsText = recipe.steps.prefix(50).joined(separator: "\n")
        return draft
    }

    /// The page's address as the source link; a tracking-laden one past the 2,048-character limit loses its query.
    private static func sourceLink(_ url: URL) -> String {
        guard url.absoluteString.count > 2048, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    /// Recipe lines run long ("kidney beans, drained and rinsed"); the item is what comes before the first comma.
    static func ingredientName(_ name: String) -> String {
        guard MealDraft.length(name) > 60 else { return name }
        let head = name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
        return clamped(head.trimmingCharacters(in: .whitespaces), to: 60)
    }

    /// Trims whole characters until it fits the limit as `MealDraft` counts it, so an emoji is never cut in half.
    static func clamped(_ text: String, to limit: Int) -> String {
        var text = text
        while MealDraft.length(text) > limit { text.removeLast() }
        return text
    }
}
