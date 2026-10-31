import Foundation

/// One member's allergies, as the matcher needs them. Allergy data stays on device (spec).
struct MemberAllergies: Hashable, Sendable {
    let memberID: UUID
    let firstName: String
    let allergens: Set<Allergen>
    let customTexts: [String]

    init(memberID: UUID, firstName: String, allergens: Set<Allergen> = [], customTexts: [String] = []) {
        self.memberID = memberID
        self.firstName = firstName
        self.allergens = allergens
        self.customTexts = customTexts
    }

    /// Whether there's anything the matcher could flag: `.custom` alone, or blank text, isn't.
    var hasAllergies: Bool {
        allergens.contains { $0 != .custom } || customTexts.contains { !Words($0).tokens.isEmpty }
    }
}

/// "Contains milk (Nora)": what a dish contains, who it affects, and which ingredients set it off.
struct AllergyFlag: Hashable, Sendable {
    enum Trigger: Hashable, Sendable {
        case allergen(Allergen)
        /// A member's Other text, as they typed it.
        case custom(String)

        var displayName: String {
            switch self {
            case .allergen(let allergen): allergen.displayName
            case .custom(let text): text
            }
        }
    }

    struct Member: Hashable, Sendable {
        let id: UUID
        let firstName: String
    }

    let trigger: Trigger
    let members: [Member]
    let ingredients: [String]

    var summary: String {
        let names = members.map(\.firstName).joined(separator: ", ")
        return String(localized: "Contains \(trigger.displayName) (\(names))", comment: "Allergy flag: allergen, then who")
    }
}

/// What a screen says about a dish's allergies: its flags, and a note when it can't say. Empty means nothing to warn about.
struct AllergyCheck: Equatable, Sendable {
    var flags: [AllergyFlag] = []
    var note: String? = nil

    /// Everything said, for VoiceOver.
    var texts: [String] { flags.map(\.summary) + [note].compactMap { $0 } }
}

/// Whether a dish missing from the library means anything yet.
enum LibraryLookup: Equatable, Sendable {
    /// A load is running, or none has started: wait for it rather than warn.
    case loading
    /// The last load gave no answer. The dish and the family's allergies may be unknown, or read a while ago and out of date:
    /// what it can find keeps its last flags, and what it can't says it couldn't be checked, to everyone.
    case failed
    /// The library and the allergies have just been read.
    case loaded
}

/// Flags dishes against the household's allergies by keyword, never by AI. Pure and deterministic, so the
/// library, day cards, and shopping list all agree, and flags never reorder between launches or devices.
enum AllergyMatcher {
    /// The standard allergens an ingredient name contains. Never `.custom`; custom text is matched per member.
    static func allergens(in ingredientName: String) -> Set<Allergen> {
        allergens(in: Words(ingredientName))
    }

    /// One flag per allergen or custom text that the dish contains and someone at the table can't have.
    /// Flags come in chip order, then custom text alphabetically; members by first name; ingredients in meal order.
    /// A category word typed under Other ("dairy") also puts that member on the real allergen's flag.
    static func flags(ingredients: [String], members: [MemberAllergies]) -> [AllergyFlag] {
        let ingredients = uniqued(ingredients)
        let members = members.sorted(by: byFirstName)
        let words = ingredients.map(Words.init)
        let found = words.map(allergens(in:))

        let standard: [AllergyFlag] = Allergen.allCases.filter { $0 != .custom }.compactMap { allergen in
            let affected = members.filter { effectiveAllergens($0).contains(allergen) }
            let matching = ingredients.indices.filter { found[$0].contains(allergen) }.map { ingredients[$0] }
            return flag(.allergen(allergen), affected, matching)
        }

        let custom: [AllergyFlag] = customGroups(members).compactMap { group in
            let matching = ingredients.indices.filter { words[$0].startsWords(group.phrase) }.map { ingredients[$0] }
            return flag(.custom(group.text), group.members, matching)
        }
        return standard + custom
    }

    /// A dish or a side with no ingredients can't set off a flag, and no flag mustn't read as safe. Only said when someone
    /// at the table has allergies to check: a family with none recorded never hears about it.
    static func uncheckedNote(meal: LibraryMeal, library: [LibraryMeal], members: [MemberAllergies]) -> String? {
        guard members.contains(where: \.hasAllergies) else { return nil }
        guard !meal.ingredients.isEmpty else {
            return String(localized: "No ingredients yet, so allergies can't be checked")
        }
        let bareSides = ShoppingLines.sideMeals(of: meal, library: library).filter(\.ingredients.isEmpty).map(\.name)
        guard !bareSides.isEmpty else { return nil }
        let names = bareSides.formatted(.list(type: .and))
        return String(localized: "No ingredients for \(names) yet, so allergies can't be checked",
                      comment: "A note on a dish: side dishes with no ingredients")
    }

    /// A library dish's flags and note, sides included. `library` is the whole library, whatever's on screen: sides are found there.
    static func check(meal: LibraryMeal, library: [LibraryMeal], members: [MemberAllergies]) -> AllergyCheck {
        AllergyCheck(flags: flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name), members: members),
                     note: uncheckedNote(meal: meal, library: library, members: members))
    }

    /// A starter dish not yet in the library: its own ingredients are all there is.
    static func check(catalog dish: CatalogDish, members: [MemberAllergies]) -> AllergyCheck {
        let isBare = dish.ingredients.isEmpty && members.contains(where: \.hasAllergies)
        return AllergyCheck(flags: flags(ingredients: dish.ingredients, members: members),
                            note: isBare ? String(localized: "No ingredients yet, so allergies can't be checked") : nil)
    }

    private static let compiledKeywords = AllergenKeywords.all.map(CompiledKeywords.init)

    private static let categoryWords = AllergenKeywords.categoryWords.map { (Words($0.phrase).tokens, $0.allergens) }

    private static func allergens(in words: Words) -> Set<Allergen> {
        Set(compiledKeywords.filter { $0.isFound(in: words) }.map(\.allergen))
    }

    private static func effectiveAllergens(_ member: MemberAllergies) -> Set<Allergen> {
        member.customTexts.map(Words.init).reduce(member.allergens) { allergens, typed in
            categoryWords.filter { typed.contains($0.0) }.reduce(allergens) { $0.union($1.1) }
        }
    }

    private static func flag(_ trigger: AllergyFlag.Trigger, _ members: [MemberAllergies],
                             _ ingredients: [String]) -> AllergyFlag? {
        guard !members.isEmpty, !ingredients.isEmpty else { return nil }
        return AllergyFlag(trigger: trigger,
                           members: members.map { AllergyFlag.Member(id: $0.memberID, firstName: $0.firstName) },
                           ingredients: ingredients)
    }

    private struct CustomGroup {
        let key: String
        let text: String
        let phrase: [Word]
        let members: [MemberAllergies]
    }

    /// Members who typed the same text (ignoring case and spacing) share one flag, shown with the first
    /// member's spelling. Plural spellings stay separate flags; each still matches both forms.
    private static func customGroups(_ sortedMembers: [MemberAllergies]) -> [CustomGroup] {
        var order: [String] = []
        var groups: [String: (text: String, members: [MemberAllergies])] = [:]
        for member in sortedMembers {
            for text in member.customTexts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = Words(trimmed).tokens.map(\.text).joined(separator: " ")
                guard !key.isEmpty else { continue }
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = (trimmed, [])
                }
                if groups[key]?.members.last?.memberID != member.memberID {
                    groups[key]?.members.append(member)
                }
            }
        }
        return order.compactMap { key in
            groups[key].map { CustomGroup(key: key, text: $0.text, phrase: Words(key).tokens, members: $0.members) }
        }
        .sorted { ordered($0.text, $1.text, tieBreak: $0.key < $1.key) }
    }

    private static func byFirstName(_ lhs: MemberAllergies, _ rhs: MemberAllergies) -> Bool {
        ordered(lhs.firstName, rhs.firstName, tieBreak: lhs.memberID.uuidString < rhs.memberID.uuidString)
    }

    /// Case- and accent-blind, but not locale-aware, so every device sorts the same way.
    private static func ordered(_ lhs: String, _ rhs: String, tieBreak: Bool) -> Bool {
        switch lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs == rhs ? tieBreak : lhs < rhs
        }
    }

    private static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// A word in an ingredient or dish name, with the spellings it could have as a singular, so "strawberries" meets
/// "strawberry" and "eggs" meets "egg". Deliberately naive English: good enough for grocery words, and
/// a rare over-match ("codes" meets "cod") is safer than a miss.
struct Word: Sendable {
    let text: String
    let forms: Set<String>

    init(_ text: String) {
        self.text = text
        var forms: Set<String> = [text]
        if text.count >= 4, text.hasSuffix("s"), !text.hasSuffix("ss") {
            forms.insert(String(text.dropLast()))
            if text.hasSuffix("es") { forms.insert(String(text.dropLast(2))) }
            if text.hasSuffix("ies") { forms.insert(String(text.dropLast(3)) + "y") }
        }
        self.forms = forms
    }

    func matches(_ other: Word) -> Bool {
        !forms.isDisjoint(with: other.forms)
    }

    func starts(with other: Word) -> Bool {
        other.forms.contains { text.hasPrefix($0) }
    }

    func hasPrefix(_ stem: String) -> Bool {
        forms.contains { $0.hasPrefix(stem) }
    }

    func hasSuffix(_ stem: String) -> Bool {
        forms.contains { $0.hasSuffix(stem) }
    }
}

/// An ingredient or dish name as whole words: case, accents, apostrophes, and punctuation folded away,
/// so "Shepherd's", "Half & Half", and "JALAPEÑO" all read like plain grocery words.
struct Words: Sendable {
    let tokens: [Word]

    init(_ text: String) {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .filter { $0 != "'" && $0 != "\u{2019}" }
        tokens = folded.split { !($0.isLetter || $0.isNumber) }.map { Word(String($0)) }
    }

    /// Where `phrase` starts, word for word.
    func occurrences(of phrase: [Word]) -> [Range<Int>] {
        occurrences(of: phrase) { $0.matches($1) }
    }

    func contains(_ phrase: [Word]) -> Bool {
        !occurrences(of: phrase).isEmpty
    }

    /// Like `contains`, but each word may run on: "corn" finds "cornstarch", "oat" finds "oatmeal".
    /// Custom text uses this, since a guardian can't list every compound; "corned beef" is a fair price.
    func startsWords(_ phrase: [Word]) -> Bool {
        !occurrences(of: phrase) { $0.matches($1) || $0.starts(with: $1) }.isEmpty
    }

    /// Single words that start or end with a stem ("cheesecake", "monkfish").
    func compounds(starting starts: [String], ending ends: [String]) -> [Range<Int>] {
        tokens.indices.filter { index in
            let word = tokens[index]
            return starts.contains(where: word.hasPrefix) || ends.contains(where: word.hasSuffix)
        }
        .map { $0..<($0 + 1) }
    }

    private func occurrences(of phrase: [Word], where match: (Word, Word) -> Bool) -> [Range<Int>] {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return [] }
        return (0...(tokens.count - phrase.count)).compactMap { start in
            let range = start..<(start + phrase.count)
            return zip(tokens[range], phrase).allSatisfy(match) ? range : nil
        }
    }
}

private struct CompiledKeywords: Sendable {
    let allergen: Allergen
    let phrases: [[Word]]
    let wordStarts: [String]
    let wordEnds: [String]
    let lookalikes: [[Word]]
    let freeFrom: [[Word]]

    private static let free = Word("free")
    /// "Free-range eggs" are eggs.
    private static let notFreeFrom: Set<String> = ["range", "ranging", "roaming", "roam", "run", "farmed"]

    init(_ keywords: AllergenKeywords) {
        allergen = keywords.allergen
        phrases = keywords.phrases.map { Words($0).tokens }
        wordStarts = keywords.wordStarts
        wordEnds = keywords.wordEnds
        lookalikes = keywords.lookalikes.map { Words($0).tokens }
        freeFrom = keywords.freeFrom.map { Words($0).tokens }
    }

    func isFound(in words: Words) -> Bool {
        guard !freeFrom.contains(where: words.contains) else { return false }
        let ruledOut = lookalikes.flatMap(words.occurrences)
        let hits = (phrases.flatMap(words.occurrences) + words.compounds(starting: wordStarts, ending: wordEnds))
            .filter { hit in !ruledOut.contains { $0.overlaps(hit) } }
        return !hits.isEmpty && !hits.contains { saysFree(after: $0, in: words.tokens) }
    }

    private func saysFree(after hit: Range<Int>, in tokens: [Word]) -> Bool {
        guard hit.upperBound < tokens.count, tokens[hit.upperBound].matches(Self.free) else { return false }
        let next = hit.upperBound + 1
        return next >= tokens.count || !Self.notFreeFrom.contains(tokens[next].text)
    }
}
