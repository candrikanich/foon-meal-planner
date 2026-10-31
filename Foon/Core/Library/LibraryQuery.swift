import Foundation

/// Filter chips on the library screen (docs/spec.md → Library screen). One at a time; none shows the rotation.
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case favorites, quick, trying, backup, allergyFlags, archived

    var id: Self { self }

    var title: String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .quick: String(localized: "Quick")
        case .trying: String(localized: "Trying")
        case .backup: String(localized: "Backup dinners")
        case .allergyFlags: String(localized: "Allergy flags")
        case .archived: String(localized: "Archived")
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case notLately, mostMade, familyFavorites, recentlyAdded

    var id: Self { self }

    var title: String {
        switch self {
        case .notLately: String(localized: "Haven't had in a while")
        case .mostMade: String(localized: "Most made")
        case .familyFavorites: String(localized: "Family favorites")
        case .recentlyAdded: String(localized: "Recently added")
        }
    }
}

/// One tile on the library grid: the meal plus what the household knows about it.
struct LibraryEntry: Identifiable, Equatable, Sendable {
    let meal: LibraryMeal
    let history: MealHistory?
    let flags: [AllergyFlag]
    let isFavorite: Bool
    /// How many people's current verdict is favorite, and how often anyone liked it: the Family favorites sort.
    var favoriteCount = 0
    var likes = 0
    /// Said in place of a flag when there's nothing to check allergies against.
    var uncheckedNote: String? = nil

    var id: UUID { meal.id }
}

/// Filtering, sorting, and search for the library. Pure, so the grid is predictable and tested.
enum LibraryQuery {
    struct CatalogSection: Identifiable, Equatable, Sendable {
        let category: String
        let dishes: [CatalogDish]

        var id: String { category }
    }

    static func entries(
        meals: [LibraryMeal], history: [MealHistory], allergies: [MemberAllergies], favorites: Set<UUID>,
        favoriteCounts: [UUID: Int] = [:], likes: [UUID: Int] = [:]
    ) -> [LibraryEntry] {
        let historyByMeal = Dictionary(history.map { ($0.mealID, $0) }, uniquingKeysWith: { first, _ in first })
        return meals.map { meal in
            LibraryEntry(
                meal: meal,
                history: historyByMeal[meal.id],
                flags: AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: meals).map(\.name),
                                            members: allergies),
                isFavorite: favorites.contains(meal.id),
                favoriteCount: favoriteCounts[meal.id] ?? 0,
                likes: likes[meal.id] ?? 0,
                uncheckedNote: AllergyMatcher.uncheckedNote(meal: meal, library: meals, members: allergies)
            )
        }
    }

    static func apply(_ entries: [LibraryEntry], filter: LibraryFilter?, sort: LibrarySort, search: String) -> [LibraryEntry] {
        let terms = searchTerms(search)
        return entries
            .filter { entry in
                let fields = searchable(entry.meal)
                return matches(entry, filter) && terms.allSatisfy { term in fields.contains { $0.contains(term) } }
            }
            .sorted(by: ordering(sort))
    }

    /// Starter dishes matching a search, shown below the family's own; dishes already copied in are skipped.
    static func catalogMatches(_ catalog: [CatalogDish], search: String, library: [LibraryMeal]) -> [CatalogDish] {
        let terms = searchTerms(search)
        guard !terms.isEmpty else { return [] }
        let copied = copiedDishIDs(library)
        return catalog
            .filter { !copied.contains($0.id) }
            .filter { dish in
                let fields = ([dish.name] + dish.ingredients).map(fold)
                return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Starter dishes to offer a family whose library can't fill the week: popular ones first, then catalog order,
    /// skipping any already copied in.
    static func starterIdeas(_ catalog: [CatalogDish], library: [LibraryMeal], count: Int) -> [CatalogDish] {
        let copied = copiedDishIDs(library)
        return Array(catalog.filter { !copied.contains($0.id) }
            .sorted { ($0.popular ? 0 : 1, $0.sortOrder) < ($1.popular ? 0 : 1, $1.sortOrder) }
            .prefix(count))
    }

    /// Dishes in rotation not already planned this week: what Build could still draw from.
    static func unusedInRotation(_ library: [LibraryMeal], planned: Set<UUID>) -> Int {
        library.filter { $0.status.isInRotation && !planned.contains($0.id) }.count
    }

    /// Catalog dishes the library already holds, in any status. A retired copy counts: re-adding it would
    /// start its ratings over and undo the dislike rule.
    static func copiedDishIDs(_ library: [LibraryMeal]) -> Set<UUID> {
        Set(library.compactMap(\.catalogMealID))
    }

    static func catalogSections(_ catalog: [CatalogDish]) -> [CatalogSection] {
        let sorted = catalog.sorted { $0.sortOrder < $1.sortOrder }
        var order: [String] = []
        var groups: [String: [CatalogDish]] = [:]
        for dish in sorted {
            if groups[dish.category] == nil { order.append(dish.category) }
            groups[dish.category, default: []].append(dish)
        }
        return order.map { CatalogSection(category: $0, dishes: groups[$0] ?? []) }
    }

    // MARK: - Private

    private static func matches(_ entry: LibraryEntry, _ filter: LibraryFilter?) -> Bool {
        let meal = entry.meal
        guard let filter else { return meal.status.isInRotation }
        switch filter {
        case .archived: return !meal.status.isInRotation
        case .favorites: return meal.status.isInRotation && entry.isFavorite
        case .quick: return meal.status.isInRotation && meal.tags.contains(.quick)
        case .trying: return meal.status == .trial
        case .backup: return meal.status.isInRotation && meal.tags.contains(.backup)
        case .allergyFlags: return meal.status.isInRotation && !entry.flags.isEmpty
        }
    }

    private static func ordering(_ sort: LibrarySort) -> (LibraryEntry, LibraryEntry) -> Bool {
        { lhs, rhs in
            switch sort {
            case .notLately:
                // Never-made dishes are new, not forgotten, so they go last.
                switch (lhs.history?.lastMade, rhs.history?.lastMade) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            case .mostMade:
                let left = lhs.history?.timesMade ?? 0, right = rhs.history?.timesMade ?? 0
                if left != right { return left > right }
                if let leftDay = lhs.history?.lastMade, let rightDay = rhs.history?.lastMade, leftDay != rightDay {
                    return leftDay > rightDay
                }
            case .familyFavorites:
                if lhs.favoriteCount != rhs.favoriteCount { return lhs.favoriteCount > rhs.favoriteCount }
                if lhs.likes != rhs.likes { return lhs.likes > rhs.likes }
            case .recentlyAdded:
                if lhs.meal.createdAt != rhs.meal.createdAt { return lhs.meal.createdAt > rhs.meal.createdAt }
            }
            return byName(lhs.meal, rhs.meal)
        }
    }

    private static func byName(_ lhs: LibraryMeal, _ rhs: LibraryMeal) -> Bool {
        let left = fold(lhs.name), right = fold(rhs.name)
        return left != right ? left < right : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func searchable(_ meal: LibraryMeal) -> [String] {
        ([meal.name] + meal.ingredients.map(\.name)).map(fold)
    }

    private static func searchTerms(_ search: String) -> [String] {
        fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Case- and accent-insensitive, and the same on every device regardless of locale.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
