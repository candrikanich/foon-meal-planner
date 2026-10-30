import Foundation

/// The weekly list (docs/spec.md → Weekly list): the approved week's ingredients, sides included, merged by
/// household item, minus what's in stock, plus staples running low or out. Designed for one big trip.
/// Allergy notes ("Get dairy-free (Nora)") go on items that someone home that night can't have.
enum WeeklyList {
    /// A planned night: its meal (nil for a quick pick or an empty night) and who's home.
    struct Night: Equatable, Sendable {
        let mealID: UUID?
        let home: Set<UUID>
        /// Cooking twice as much, for a leftovers night (Double it): every amount on this night's lines doubles.
        var doubled = false
        /// Already cooked and in the freezer: only its sides still need buying.
        var fromFreezer = false
    }

    /// A keep-on-hand item and its stock state.
    struct Staple: Equatable, Sendable {
        let itemID: UUID
        let name: String
        let state: StockState
    }

    /// One thing to buy.
    struct Line: Equatable, Sendable {
        let itemID: UUID
        let name: String
        /// Every amount the week calls for, joined ("1 cup + 2 cups"); nil when no recipe gave one.
        let quantity: String?
        /// The meals (or sides) it's for, in the order they come up.
        let forMeals: [String]
        let note: String?
        /// A low or out staple rather than a meal ingredient.
        let isStaple: Bool
    }

    static func build(nights: [Night], library: [LibraryMeal], stock: [UUID: StockState] = [:],
                      staples: [Staple] = [], allergies: [MemberAllergies] = []) -> [Line] {
        let mealsByID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [UUID] = []
        var drafts: [UUID: Draft] = [:]

        for night in nights {
            guard let meal = night.mealID.flatMap({ mealsByID[$0] }) else { continue }
            let athome = allergies.filter { night.home.contains($0.memberID) }
            let lines = night.fromFreezer ? ShoppingLines.sides(for: meal, library: library)
                                          : ShoppingLines.lines(for: meal, library: library)
            for line in lines where stock[line.itemID] != .in {
                if drafts[line.itemID] == nil {
                    order.append(line.itemID)
                    drafts[line.itemID] = Draft(name: line.name)
                }
                drafts[line.itemID]?.add(line, doubled: night.doubled,
                                         flags: AllergyMatcher.flags(ingredients: [line.name], members: athome))
            }
        }

        let mealLines = order.compactMap { id in drafts[id].map { $0.line(itemID: id) } }
        let stapleLines = staples
            .filter { $0.state != .in && drafts[$0.itemID] == nil }
            .map { Line(itemID: $0.itemID, name: $0.name, quantity: nil, forMeals: [], note: nil, isStaple: true) }
        return mealLines + stapleLines
    }

    /// What to look for in the store, for someone who can't have it.
    static func shoppingAdvice(_ allergen: Allergen) -> String {
        switch allergen {
        case .milk: String(localized: "Get dairy-free", comment: "Shopping note for a milk allergy")
        case .eggs: String(localized: "Get egg-free", comment: "Shopping note for an egg allergy")
        case .wheat: String(localized: "Get gluten-free", comment: "Shopping note for a wheat allergy")
        case .peanuts: String(localized: "Get peanut-free", comment: "Shopping note for a peanut allergy")
        case .treeNuts: String(localized: "Get nut-free", comment: "Shopping note for a tree nut allergy")
        case .soy: String(localized: "Get soy-free", comment: "Shopping note for a soy allergy")
        case .sesame: String(localized: "Get sesame-free", comment: "Shopping note for a sesame allergy")
        case .fish: String(localized: "Skip fish", comment: "Shopping note for a fish allergy")
        case .shellfish: String(localized: "Skip shellfish", comment: "Shopping note for a shellfish allergy")
        case .custom: String(localized: "Check the label", comment: "Shopping note for an allergy typed as Other")
        }
    }

    /// One item's merged amounts, meals, and who it's flagged for.
    private struct Draft {
        let name: String
        var quantities: [String] = []
        var meals: [String] = []
        /// In the order first seen, with everyone it affects.
        var flags: [(trigger: AllergyFlag.Trigger, names: Set<String>)] = []
        init(name: String) {
            self.name = name
        }

        /// A doubled dish's amount scales here, on the way in, once per night: this is built fresh from the plan each time,
        /// so nothing scaled is ever read back and scaled again. Each part says for itself whether it's already doubled, so
        /// "3 lb (doubled) + 1 lb" can't be doubled again by hand, and notes stay for allergies.
        mutating func add(_ line: ShoppingLine, doubled: Bool = false, flags found: [AllergyFlag]) {
            if doubled {
                quantities.append(Self.doubledAmount(line.quantity))
            } else if let quantity = line.quantity {
                quantities.append(quantity)
            }
            if !meals.contains(line.forMeal) { meals.append(line.forMeal) }
            for flag in found {
                let names = Set(flag.members.map(\.firstName))
                if let index = flags.firstIndex(where: { $0.trigger == flag.trigger }) {
                    flags[index].names.formUnion(names)
                } else {
                    flags.append((flag.trigger, names))
                }
            }
        }

        func line(itemID: UUID) -> Line {
            Line(itemID: itemID, name: name, quantity: Self.joined(quantities, limit: 60), forMeals: meals,
                 note: allergyNote, isStaple: false)
        }

        private static func doubledAmount(_ quantity: String?) -> String {
            guard let quantity else {
                return String(localized: "get double", comment: "Weekly list amount: a doubled dish's ingredient with no amount to scale")
            }
            guard let scaled = QuantityScaler.scaledIfSimple(quantity, by: 2) else {
                return String(localized: "\(quantity) (get double)", comment: "Weekly list amount: as the recipe wrote it, for a doubled dish; buy twice that")
            }
            return String(localized: "\(scaled) (doubled)", comment: "Weekly list amount: already twice the recipe, for a doubled dish")
        }

        /// Every flag, always: the full notes when they fit the database's 140, else one compact line that still
        /// names each allergen ("Check: dairy, kiwi, … (Nora +2)"). Allergies are flagged, never dropped.
        private var allergyNote: String? {
            guard !flags.isEmpty else { return nil }
            let full = flags.map(Self.note).joined(separator: "; ")
            if full.unicodeScalars.count <= 140 { return full }
            let names = flags.reduce(into: Set<String>()) { $0.formUnion($1.names) }.sorted()
            let who = names.count <= 1 ? names.joined()
                : String(localized: "\(names[0]) +\(names.count - 1)", comment: "Allergy note: first name and how many more")
            var what = flags.map { String($0.trigger.displayName.prefix(24)) }
            var compact = Self.compact(what, who: who)
            while compact.unicodeScalars.count > 140, let longest = what.indices.max(by: { what[$0].count < what[$1].count }),
                  what[longest].count > 6 {
                what[longest] = String(what[longest].prefix(what[longest].count - 4)) + "…"
                compact = Self.compact(what, who: who)
            }
            return compact
        }

        private static func compact(_ what: [String], who: String) -> String {
            String(localized: "Check: \(what.joined(separator: ", ")) (\(who))",
                   comment: "Compact allergy note: everything to avoid, then who")
        }

        private static func note(_ flag: (trigger: AllergyFlag.Trigger, names: Set<String>)) -> String {
            let who = flag.names.sorted().joined(separator: ", ")
            switch flag.trigger {
            case .allergen(let allergen):
                return String(localized: "\(WeeklyList.shoppingAdvice(allergen)) (\(who))",
                              comment: "Weekly list allergy note: advice, then who it's for")
            case .custom(let text):
                return String(localized: "Check for \(text) (\(who))",
                              comment: "Weekly list note for an Other allergy: what to avoid, then who")
            }
        }

        /// Joined until the next part wouldn't fit the database's limit (code points), so a save never fails.
        /// Only for amounts: a missing amount is cosmetic, a missing allergy isn't.
        private static func joined(_ parts: [String], separator: String = " + ", limit: Int) -> String? {
            var result = ""
            for part in parts {
                let next = result.isEmpty ? part : result + separator + part
                guard next.unicodeScalars.count <= limit else { break }
                result = next
            }
            return result.isEmpty ? nil : result
        }
    }
}
