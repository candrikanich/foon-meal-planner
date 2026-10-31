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
    /// The last full load failed, so what's showing may be old. `errorMessage` also carries other actions' failures.
    private(set) var lastLoadFailed = false
    /// Whether a dish missing from `meals` means anything yet. A load that ended with no answer, failed or cancelled, reads
    /// as failed: a closed sheet can cancel the load a screen behind it was waiting on, with nothing else to decide. A
    /// failed reload does too: the allergies from the last read may be out of date, so they can't rule out a warning.
    var lookup: LibraryLookup {
        if isLoading { return .loading }
        if lastLoadFailed { return .failed }
        if hasLoaded { return .loaded }
        return loadGeneration == 0 ? .loading : .failed
    }
    /// Whether a screen holding these dishes needs a full load rather than a refresh. A note says to pull down, and a pull has
    /// to be able to find the dish: one another phone just planned, or anything after a load that failed.
    func needsFullLoad(holding mealIDs: some Sequence<UUID>) -> Bool {
        !hasLoaded || lastLoadFailed || mealIDs.contains { meal($0) == nil }
    }

    /// The same question once the screen's own data has been read, since that can bring a dish the first answer didn't know
    /// about. A full load that ran alongside it may have read too early; one that just failed waits for the next pull.
    func needsLoad(afterFullLoad ran: Bool, holding mealIDs: some Sequence<UUID>) -> Bool {
        guard ran else { return needsFullLoad(holding: mealIDs) }
        return hasLoaded && !lastLoadFailed && mealIDs.contains { meal($0) == nil }
    }

    /// For a screen that needs the library and shouldn't replace a load already running.
    func shouldStartLoad(holding mealIDs: some Sequence<UUID>) -> Bool {
        !isLoading && needsFullLoad(holding: mealIDs)
    }

    /// Dishes being copied in, so their Add buttons don't fire twice.
    private(set) var addingDishIDs: Set<UUID> = []
    /// Meals being copied (Copy and tweak), for the same reason.
    private(set) var copyingMealIDs: Set<UUID> = []

    var filter: LibraryFilter?
    var sort: LibrarySort = .notLately
    var search = ""

    private(set) var history: [MealHistory] = []
    private var itemNames: [String] = []
    /// Allergies of everyone still in the family, for flags on the library and on day cards.
    private(set) var allergies: [MemberAllergies] = []
    private var members: [Member] = []
    /// Bumped per load, so a slower, older load never overwrites a newer one.
    private var loadGeneration = 0
    /// Bumped per archive or restore, which don't reload: a read already out predates them, so it stands down.
    private var statusWrites = 0
    /// Signed photo URLs by path. Reusing one keeps `AsyncImage` on the URL cache while scrolling.
    private var photoURLs: [String: (url: URL, expires: Date)] = [:]

    let householdID: UUID
    let client: LibraryClient

    init(householdID: UUID, client: LibraryClient) {
        self.householdID = householdID
        self.client = client
    }

    /// The family's reactions: current verdicts and likes, for favorites, the sorts, and Build my week.
    private(set) var reactions = ReactionSummary()
    /// Comments this person may see: a hidden one reaches planners only.
    private(set) var comments: [MealComment] = []
    /// Everyone's serving notes, for meal detail and day cards.
    private(set) var servingNotes: [ServingNote] = []

    /// Dishes that are someone's favorite now.
    private var favorites: Set<UUID> { Set(reactions.favorites.values.flatMap { $0 }) }

    var visibleEntries: [LibraryEntry] {
        LibraryQuery.apply(entries(meals), filter: filter, sort: sort, search: search)
    }

    /// Dishes in rotation whose allergies can't be checked yet.
    var uncheckedCount: Int {
        entries(meals).filter { $0.meal.status.isInRotation && $0.uncheckedNote != nil }.count
    }

    private func entries(_ shown: [LibraryMeal]) -> [LibraryEntry] {
        let counts = Dictionary(favorites.map { ($0, reactions.favoriteCount($0)) }, uniquingKeysWith: { first, _ in first })
        return LibraryQuery.entries(meals: shown, library: meals, history: history, allergies: allergies, favorites: favorites,
                                    favoriteCounts: counts, likes: reactions.likes)
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
        let writes = statusWrites
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            async let meals = client.meals(householdID)
            async let history = client.history(householdID)
            async let catalog = client.catalog()
            async let allergyRows = client.allergies(householdID)
            async let itemNames = client.itemNames(householdID)
            async let verdicts = client.verdicts(householdID)
            async let likes = client.likes(householdID)
            async let notes = client.servingNotes(householdID)
            async let comments = client.comments(householdID)
            let loaded = try await (meals, history, catalog, allergyRows, itemNames)
            let reactions = try await ReactionSummary(verdicts: verdicts, likes: likes)
            let servingNotes = try await notes
            // Not worth failing the Library for: a failed read keeps what was shown.
            let loadedComments = (try? await comments) ?? self.comments
            // Only the newest load counts: an older read can predate a save, and can't speak for a newer load that failed.
            guard generation == loadGeneration, writes == statusWrites else { return }
            self.meals = loaded.0
            self.history = loaded.1
            self.catalog = loaded.2
            // `self.members`, not the argument: who's in the family may have changed while this was out.
            allergies = Self.memberAllergies(loaded.3, members: self.members)
            self.itemNames = loaded.4
            self.reactions = reactions
            self.servingNotes = servingNotes
            self.comments = loadedComments
            hasLoaded = true
            lastLoadFailed = false
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !Self.isCancellation(error) else { return }
            lastLoadFailed = true
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
            statusWrites += 1
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

    /// Re-reads just what the family has said since (cheap), so a dislike from last night reaches Build my week, and an
    /// allergy a parent just added, someone joining or leaving, or an edit to a dish's ingredients reaches the flags on this
    /// phone, without a full library reload. Keeps what it had if
    /// the network says no: offline never reads as no allergies. A load or save that came along meanwhile is newer, so
    /// this stands down rather than put old answers back.
    func refreshReactions(members: [Member]) async {
        self.members = members
        guard hasLoaded else { return }
        let generation = loadGeneration
        let writes = statusWrites
        // Someone removed on another phone goes now, even if what's read below doesn't arrive.
        let present = Set(members.filter { $0.status != .removed }.map(\.id))
        allergies = allergies.filter { present.contains($0.memberID) }
        do {
            async let meals = client.meals(householdID)
            async let verdicts = client.verdicts(householdID)
            async let likes = client.likes(householdID)
            async let notes = client.servingNotes(householdID)
            async let comments = client.comments(householdID)
            async let allergyRows = client.allergies(householdID)
            let loadedAllergies = try? await allergyRows
            let loadedMeals = try? await meals
            // What allergy checks read doesn't wait on the rest: if the reactions fail, these still count.
            guard generation == loadGeneration, writes == statusWrites else { return }
            if let loadedAllergies { allergies = Self.memberAllergies(loadedAllergies, members: self.members) }
            if let loadedMeals { self.meals = loadedMeals }
            let reactions = try await ReactionSummary(verdicts: verdicts, likes: likes)
            // Serving notes are family input too: a note Mom just wrote shows on Dad's cards.
            let servingNotes = try await notes
            let loadedComments = try? await comments
            guard generation == loadGeneration else { return }
            self.reactions = reactions
            self.servingNotes = servingNotes
            if let loadedComments { self.comments = loadedComments }
        } catch {
            // Offline: last load's reactions still stand.
        }
    }

    func comments(for mealID: UUID) -> [MealComment] {
        comments.filter { $0.mealID == mealID }
    }

    /// Hides a comment from the family, or brings it back. Nothing's deleted. Returns whether it saved.
    @discardableResult
    func setCommentHidden(_ comment: MealComment, hidden: Bool) async -> Bool {
        do {
            try await client.setCommentHidden(comment.id, hidden)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index].hidden = hidden }
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PostgrestError)?.code == "42501"
                ? String(localized: "Only planners can hide a comment.")
                : String(localized: "Couldn't change that comment. Check your connection and try again.")
            return false
        }
    }

    func servingNotes(for mealID: UUID) -> [ServingNote] {
        servingNotes.filter { $0.mealID == mealID }
    }

    /// Saves (or, blank, clears) a member's note on a dish. Returns whether it saved.
    @discardableResult
    func setServingNote(_ note: String, mealID: UUID, memberID: UUID) async -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServingNote.length(trimmed) <= ServingNote.maxLength else {
            errorMessage = String(localized: "Serving notes need 120 characters or fewer.")
            return false
        }
        do {
            try await client.setServingNote(mealID, memberID, trimmed)
            servingNotes = try await client.servingNotes(householdID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = switch (error as? PostgrestError)?.code {
            case "42501": String(localized: "People write their own notes; parents can write anyone's.")
            case "23514": String(localized: "Serving notes need 120 characters or fewer.")
            default: String(localized: "Couldn't save the note. Check your connection and try again.")
            }
            return false
        }
    }

    /// Shows what a parent just saved, so flags and their profile are right whether or not the reload that follows gets
    /// through. That reload also drops any older one still out, which would bring the old allergies back.
    func showAllergies(_ saved: AllergyChoice, for member: Member, members: [Member]) async {
        let others = allergies.filter { $0.memberID != member.id }
        allergies = saved.isEmpty ? others : others + [
            MemberAllergies(memberID: member.id, firstName: member.firstName, allergens: saved.allergens,
                            customTexts: saved.custom.sorted())
        ]
        await load(members: members)
    }

    func meal(_ id: UUID) -> LibraryMeal? {
        meals.first { $0.id == id }
    }

    func entry(_ id: UUID) -> LibraryEntry? {
        entries(meals.filter { $0.id == id }).first
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
        return await create(draft)
    }

    /// Reads a recipe link. Nil (with a message) when the link can't be opened or read.
    func importRecipe(_ link: String) async -> RecipeImport? {
        guard let url = Self.webLink(link) else {
            errorMessage = String(localized: "That doesn't look like a web link.")
            return nil
        }
        do {
            let imported = try await client.importRecipe(url.absoluteString)
            errorMessage = nil
            return imported
        } catch RecipeImportError.notAllowed {
            errorMessage = String(localized: "Foon can't open that link. Try the recipe's web page.")
        } catch {
            errorMessage = String(localized: "Couldn't read that page. Check your connection and try again.")
        }
        return nil
    }

    /// A typed or pasted link as a web address; "recipes.example/chili" gets https.
    nonisolated static func webLink(_ link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host()?.contains(".") == true else { return nil }
        return url
    }

    /// Adds a new meal from a draft (quick add, a recipe link) and returns its id.
    func create(_ draft: MealDraft) async -> UUID? {
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
    /// Archived dishes come back with a tap; retired ones too, after a confirmation, since the family voted them out
    /// (the dislikes still keep them off nights those people are home).
    static func canRestore(_ meal: LibraryMeal) -> Bool {
        meal.status == .archived || meal.status == .retired
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
