import Foundation

/// A meal being edited. Plain text fields while typing; `validated()` turns them into what `save_meal` stores,
/// with the same limits the database enforces so the editor never offers a save the server refuses.
struct MealDraft: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: UUID
        var quantity: String
        var name: String

        init(id: UUID = UUID(), quantity: String, name: String) {
            self.id = id
            self.quantity = quantity
            self.name = name
        }
    }

    /// What `save_meal` receives.
    struct Saved: Equatable, Sendable {
        struct Line: Equatable, Sendable, Encodable {
            let name: String
            let quantity: String?
        }

        /// `{"meal_id": …}` or `{"name": …}`, as save_meal reads them.
        enum Side: Equatable, Sendable, Encodable {
            case meal(UUID)
            case item(String)

            private enum CodingKeys: String, CodingKey {
                case mealID = "meal_id"
                case name
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .meal(let id): try container.encode(id, forKey: .mealID)
                case .item(let name): try container.encode(name, forKey: .name)
                }
            }
        }

        let name: String
        let servings: Int
        let tags: [MealTag]
        let steps: [String]
        let sourceURL: URL?
        let madeByMemberID: UUID?
        let lines: [Line]
        var sides: [Side] = []
    }

    /// A side while editing: a library meal by id, or an item by name.
    enum Side: Equatable, Hashable, Sendable {
        case meal(UUID)
        case item(String)
    }

    enum Problem: Error, Equatable {
        case nameMissing, nameTooLong, servings, badLink, ingredientTooLong, tooManySteps, stepsTooLong

        var message: String {
            switch self {
            case .nameMissing: String(localized: "Give the meal a name.")
            case .nameTooLong: String(localized: "Meal names need 80 characters or fewer.")
            case .servings: String(localized: "Servings go from 1 to 50.")
            case .badLink: String(localized: "That link doesn't look like a web address.")
            case .ingredientTooLong: String(localized: "Ingredient names and amounts need 60 characters or fewer.")
            case .tooManySteps: String(localized: "Recipes can have up to 50 steps.")
            case .stepsTooLong: String(localized: "The recipe steps are too long.")
            }
        }
    }

    var name: String
    var servings: Int
    var tags: Set<MealTag>
    var lines: [Line]
    /// One step per line.
    var stepsText: String
    var link: String
    var madeByMemberID: UUID?
    var sides: [Side]

    init(_ meal: LibraryMeal) {
        name = meal.name
        servings = meal.servings
        tags = Set(meal.tags)
        lines = meal.ingredients.map { Line(quantity: $0.quantityText ?? "", name: $0.name) }
        stepsText = meal.steps.joined(separator: "\n")
        link = meal.sourceURL?.absoluteString ?? ""
        madeByMemberID = meal.madeByMemberID
        sides = meal.sides.map { side in
            switch side {
            case .meal(let id): .meal(id)
            case .item(_, let name): .item(name)
            }
        }
        mealID = meal.id
    }

    /// A new meal for quick add: just a name, the usual servings, nothing else yet.
    init(newNamed name: String) {
        self.name = name
        servings = 4
        tags = []
        lines = []
        stepsText = ""
        link = ""
        madeByMemberID = nil
        sides = []
        mealID = nil
    }

    /// The meal being edited, so it's never offered as its own side.
    private let mealID: UUID?

    /// Adds a side typed by name: a library meal when the name matches one, otherwise a simple item.
    mutating func addSide(_ typed: String, library: [LibraryMeal]) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // A retired dish is one the family voted out; it doesn't come back as a side.
        let match = library.first {
            $0.id != mealID && $0.status != .retired && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        let side: Side = match.map { .meal($0.id) } ?? .item(name)
        let isRepeat = sides.contains { existing in
            switch (existing, side) {
            case let (.item(old), .item(new)): old.caseInsensitiveCompare(new) == .orderedSame
            default: existing == side
            }
        }
        if !isRepeat { sides.append(side) }
    }

    /// Adds typed or pasted ingredients ("1 lb ground beef, taco shells") as lines.
    mutating func addIngredients(_ text: String) {
        lines += IngredientParser.parse(text).map { Line(quantity: $0.quantity ?? "", name: $0.name) }
    }

    func validated() throws(Problem) -> Saved {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .nameMissing }
        guard Self.length(name) <= 80 else { throw .nameTooLong }
        guard (1...50).contains(servings) else { throw .servings }

        var savedLines: [Saved.Line] = []
        for line in lines {
            let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let quantity = line.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard Self.length(name) <= 60, Self.length(quantity) <= 60 else { throw .ingredientTooLong }
            savedLines.append(Saved.Line(name: name, quantity: quantity.isEmpty ? nil : quantity))
        }

        let steps = stepsText.split(whereSeparator: \.isNewline).map(Self.withoutNumbering).filter { !$0.isEmpty }
        guard steps.count <= 50 else { throw .tooManySteps }
        guard Self.length(steps.joined()) <= 20_000 else { throw .stepsTooLong }

        var savedSides: [Saved.Side] = []
        for side in sides {
            switch side {
            case .meal(let id):
                savedSides.append(.meal(id))
            case .item(let typed):
                let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                guard Self.length(name) <= 60 else { throw .ingredientTooLong }
                savedSides.append(.item(name))
            }
        }

        return Saved(
            name: name, servings: servings, tags: MealTag.allCases.filter(tags.contains), steps: steps,
            sourceURL: try Self.webLink(link), madeByMemberID: madeByMemberID, lines: savedLines, sides: savedSides
        )
    }

    /// The name a copy starts with; the editor opens right away so it can be renamed.
    static func copyName(for name: String) -> String {
        var copy = String(localized: "\(name) (copy)", comment: "Copy and tweak: the copied meal's starting name")
        // Trim whole characters, so an emoji is never cut in half.
        while length(copy) > 80 { copy.removeLast() }
        return copy
    }

    /// Postgres `char_length` counts code points, not the characters people see: a family emoji is 5.
    static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// "1. Brown the beef", "2) …", "- …", and "Step 3: …" all become the step itself.
    private static func withoutNumbering(_ line: Substring) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A digit right after the mark means a quantity or a time ("1.5 cups", "10:30"), not numbering.
        let pattern = /^(?:(?:[Ss]tep\s*)?\d+\s*[.):](?!\d)|[-*•])\s*/
        return trimmed.replacing(pattern, with: "", maxReplacements: 1).trimmingCharacters(in: .whitespaces)
    }

    private static func webLink(_ typed: String) throws(Problem) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard !withScheme.contains(where: \.isWhitespace),
              let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(), host.contains("."),
              // Measured as stored: non-ASCII becomes percent-encoded and grows.
              length(url.absoluteString) <= 2048
        else { throw .badLink }
        return url
    }
}

/// Words for the meal detail screen, kept out of the view so they're testable and localizable.
enum MealText {
    static func history(_ history: MealHistory?, calendar: Calendar = .current) -> String {
        guard let history else { return String(localized: "Not made yet") }
        let day = history.lastMade.date(in: calendar)
            .formatted(Date.FormatStyle(calendar: calendar).month(.abbreviated).day())
        return history.timesMade == 1
            ? String(localized: "Made once, last on \(day)")
            : String(localized: "Made \(history.timesMade) times, last on \(day)")
    }

    static func leadTime(hours: Int?) -> String? {
        guard let hours else { return nil }
        if hours >= 24, hours % 24 == 0 {
            let days = hours / 24
            return days == 1 ? String(localized: "1 day ahead") : String(localized: "\(days) days ahead")
        }
        return hours == 1 ? String(localized: "1 hour ahead") : String(localized: "\(hours) hours ahead")
    }
}
