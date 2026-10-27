import Foundation
import Observation
import Supabase

/// The library screen's state: the household's meals, the catalog, and the chosen filter, sort, and search.
@Observable @MainActor
final class LibraryStore {
    private(set) var meals: [LibraryMeal] = []
    private(set) var catalog: [CatalogDish] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Dishes being copied in, so their Add buttons don't fire twice.
    private(set) var addingDishIDs: Set<UUID> = []
    /// Meals being copied (Copy and tweak), for the same reason.
    private(set) var copyingMealIDs: Set<UUID> = []

    var filter: LibraryFilter?
    var sort: LibrarySort = .notLately
    var search = ""

    private var history: [MealHistory] = []
    private var itemNames: [String] = []
    private var allergies: [MemberAllergies] = []
    private var members: [Member] = []
    /// Bumped per load, so a slower, older load never overwrites a newer one.
    private var loadGeneration = 0
    /// Signed photo URLs by path. Reusing one keeps `AsyncImage` on the URL cache while scrolling.
    private var photoURLs: [String: (url: URL, expires: Date)] = [:]

    let householdID: UUID
    let client: LibraryClient

    init(householdID: UUID, client: LibraryClient) {
        self.householdID = householdID
        self.client = client
    }

    /// Favorites come from ratings (M2); until then the Favorites chip shows its empty state.
    private var favorites: Set<UUID> { [] }

    var visibleEntries: [LibraryEntry] {
        LibraryQuery.apply(
            LibraryQuery.entries(meals: meals, history: history, allergies: allergies, favorites: favorites),
            filter: filter, sort: sort, search: search
        )
    }

    var catalogMatches: [CatalogDish] {
        LibraryQuery.catalogMatches(catalog, search: search, library: meals)
    }

    var catalogSections: [LibraryQuery.CatalogSection] {
        LibraryQuery.catalogSections(catalog)
    }

    func isInLibrary(_ dish: CatalogDish) -> Bool {
        LibraryQuery.copiedDishIDs(meals).contains(dish.id)
    }

    func member(_ id: UUID?) -> Member? {
        members.first { $0.id == id }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Reloads with the members from the last load, after a change made elsewhere (an item's note).
    func reload() async {
        await load(members: members)
    }

    /// Loads everything the screen shows. A failure keeps what was already on screen; a cancelled load
    /// (the view went away, or members changed and a new load started) is not an error.
    func load(members: [Member]) async {
        self.members = members
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            async let meals = client.meals(householdID)
            async let history = client.history(householdID)
            async let catalog = client.catalog()
            async let allergyRows = client.allergies(householdID)
            async let itemNames = client.itemNames(householdID)
            let loaded = try await (meals, history, catalog, allergyRows, itemNames)
            guard generation == loadGeneration else { return }
            self.meals = loaded.0
            self.history = loaded.1
            self.catalog = loaded.2
            allergies = Self.memberAllergies(loaded.3, members: members)
            self.itemNames = loaded.4
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !Self.isCancellation(error) else { return }
            errorMessage = String(localized: "Couldn't load your library. Check your connection and try again.")
        }
    }

    func setArchived(_ archived: Bool, mealID: UUID) async {
        guard meals.contains(where: { $0.id == mealID }) else { return }
        let status: MealStatus = archived ? .archived : .active
        do {
            try await client.setStatus(mealID, status)
            // Look again: a reload may have replaced the list while the request was out.
            if let index = meals.firstIndex(where: { $0.id == mealID }) { meals[index].status = status }
            errorMessage = nil
        } catch {
            errorMessage = archived
                ? String(localized: "Couldn't archive that meal. Check your connection and try again.")
                : String(localized: "Couldn't restore that meal. Check your connection and try again.")
        }
    }

    /// Copies a starter dish into the library and returns the new meal's id.
    @discardableResult
    func add(_ dish: CatalogDish) async -> UUID? {
        guard !addingDishIDs.contains(dish.id) else { return nil }
        addingDishIDs.insert(dish.id)
        defer { addingDishIDs.remove(dish.id) }
        do {
            let id = try await client.addFromCatalog(householdID, dish.id)
            await load(members: members)
            return id
        } catch {
            errorMessage = String(localized: "Couldn't add \(dish.name). Check your connection and try again.")
            return nil
        }
    }

    func meal(_ id: UUID) -> LibraryMeal? {
        meals.first { $0.id == id }
    }

    func entry(_ id: UUID) -> LibraryEntry? {
        LibraryQuery.entries(meals: meals.filter { $0.id == id }, history: history, allergies: allergies,
                             favorites: favorites).first
    }

    /// What a meal is served with, by name. A side meal no longer in the library, or retired, is left out.
    func sideNames(for meal: LibraryMeal) -> [String] {
        meal.sides.compactMap { side in
            switch side {
            case .meal(let id): self.meal(id).flatMap { $0.status == .retired ? nil : $0.name }
            case .item(_, let name): name
            }
        }
    }

    /// Every item the household has used, in meals or on lists, for autocomplete while typing.
    var ingredientNames: [String] {
        Array(Set(meals.flatMap { $0.ingredients.map(\.name) } + itemNames))
    }

    var activeMembers: [Member] {
        members.filter { $0.status != .removed }
    }

    /// Saves an edited meal. Problems the editor can explain stop before the server.
    func save(_ draft: MealDraft, mealID: UUID) async -> Bool {
        let saved: MealDraft.Saved
        do {
            saved = try draft.validated()
        } catch {
            errorMessage = error.message
            return false
        }
        do {
            try await client.save(mealID, saved)
            await load(members: members)
            return true
        } catch {
            errorMessage = Self.refusal(error)
                ?? String(localized: "Couldn't save the meal. Check your connection and try again.")
            return false
        }
    }

    func isCopying(_ meal: LibraryMeal) -> Bool {
        copyingMealIDs.contains(meal.id)
    }

    /// Quick add: a name and, optionally, ingredients typed naturally. Returns the new meal's id.
    func quickAdd(name: String, ingredients: String) async -> UUID? {
        var draft = MealDraft(newNamed: name)
        draft.addIngredients(ingredients)
        let saved: MealDraft.Saved
        do {
            saved = try draft.validated()
        } catch {
            errorMessage = error.message
            return nil
        }
        do {
            let id = try await client.create(householdID, saved)
            await load(members: members)
            return id
        } catch {
            errorMessage = Self.refusal(error)
                ?? String(localized: "Couldn't add \(saved.name). Check your connection and try again.")
            return nil
        }
    }

    /// Copy and tweak. Returns the copy's id once it's loaded, so the editor can open on it.
    func copy(_ meal: LibraryMeal) async -> UUID? {
        guard Self.canCopy(meal), !copyingMealIDs.contains(meal.id) else { return nil }
        copyingMealIDs.insert(meal.id)
        defer { copyingMealIDs.remove(meal.id) }
        do {
            let id = try await client.copy(meal.id, MealDraft.copyName(for: meal.name))
            await load(members: members)
            guard self.meal(id) != nil else {
                errorMessage = String(localized: "The copy was made but hasn't loaded yet. Pull to refresh the library.")
                return nil
            }
            return id
        } catch {
            errorMessage = Self.refusal(error)
                ?? String(localized: "Couldn't copy \(meal.name). Check your connection and try again.")
            return nil
        }
    }

    func reportPhotoLoadFailure() {
        errorMessage = String(localized: "Couldn't open that photo. Try another one.")
    }

    /// Replaces the meal's photo. The picture is re-encoded first, which strips location and other metadata.
    func setPhoto(_ imageData: Data, for meal: LibraryMeal) async -> Bool {
        let prepared: Data
        do {
            prepared = try PhotoPreparation.prepare(imageData)
        } catch {
            errorMessage = String(localized: "That file isn't a photo Foon can use.")
            return false
        }
        do {
            try await client.setPhoto(meal, prepared)
            await load(members: members)
            return true
        } catch {
            errorMessage = Self.refusal(error)
                ?? String(localized: "Couldn't upload the photo. Check your connection and try again.")
            return false
        }
    }

    func photoURL(for path: String) async throws -> URL {
        if let cached = photoURLs[path], cached.expires > .now { return cached.url }
        let url = try await client.photoURL(path)
        // Refresh a little before the signed URL lapses.
        photoURLs[path] = (url, .now.addingTimeInterval(Double(PhotoStorageClient.signedURLLifetime) - 60))
        return url
    }

    /// A retired meal isn't copied: the copy would start its ratings over and undo the dislike rule.
    static func canCopy(_ meal: LibraryMeal) -> Bool {
        meal.status != .retired
    }

    /// The server said no for a reason worth showing, rather than a connection problem.
    static func refusal(_ error: any Error) -> String? {
        if case LibraryClientError.notAllowed = error {
            return String(localized: "You can't change this meal. Only planners can.")
        }
        switch (error as? PostgrestError)?.code {
        case "42501": return String(localized: "You can't change this meal. Only planners can.")
        case "P0002": return String(localized: "That meal isn't in your library anymore. Pull to refresh.")
        case "23514", "22001": return String(localized: "Something in this meal is too long to save.")
        default: return nil
        }
    }

    /// Only archived meals come back; retired ones were dropped by the family's dislikes.
    static func canRestore(_ meal: LibraryMeal) -> Bool {
        meal.status == .archived
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Planners (and the owner during onboarding) manage the library; everyone else browses.
    static func canEdit(me: Member?, isOwner: Bool) -> Bool {
        isOwner || me?.role == .planner
    }

    /// Allergies of everyone still in the family, as the matcher wants them. Removed members don't flag dishes.
    static func memberAllergies(_ rows: [AllergyRow], members: [Member]) -> [MemberAllergies] {
        members.filter { $0.status != .removed }.compactMap { member in
            let own = rows.filter { $0.memberID == member.id }
            guard !own.isEmpty else { return nil }
            return MemberAllergies(
                memberID: member.id,
                firstName: member.firstName,
                allergens: Set(own.map(\.allergen).filter { $0 != .custom }),
                customTexts: own.filter { $0.allergen == .custom }.compactMap(\.customText)
            )
        }
    }
}
