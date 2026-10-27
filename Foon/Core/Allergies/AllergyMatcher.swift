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
        "Contains \(trigger.displayName) (\(members.map(\.firstName).joined(separator: ", ")))"
    }
}

/// Flags dishes against the household's allergies by keyword, never by AI. Pure and deterministic, so the
/// library, day cards, and shopping list all agree, and flags never reorder between launches.
enum AllergyMatcher {
    /// The standard allergens an ingredient name contains. Never `.custom`; custom text is matched per member.
    static func allergens(in ingredientName: String) -> Set<Allergen> {
        allergens(in: Words(ingredientName))
    }

    /// One flag per allergen or custom text that the dish contains and someone at the table can't have.
    /// Flags come in chip order, then custom text alphabetically; members by first name; ingredients in meal order.
    static func flags(ingredients: [String], members: [MemberAllergies]) -> [AllergyFlag] {
        let ingredients = uniqued(ingredients)
        let members = members.sorted(by: byFirstName)
        let words = ingredients.map(Words.init)
        let found = words.map(allergens(in:))

        let standard: [AllergyFlag] = Allergen.allCases.filter { $0 != .custom }.compactMap { allergen in
            let affected = members.filter { $0.allergens.contains(allergen) }
            let matching = ingredients.indices.filter { found[$0].contains(allergen) }.map { ingredients[$0] }
            return flag(.allergen(allergen), affected, matching)
        }

        let custom: [AllergyFlag] = customGroups(members).compactMap { group in
            let matching = ingredients.indices.filter { words[$0].contains(group.phrase) }.map { ingredients[$0] }
            return flag(.custom(group.text), group.members, matching)
        }
        return standard + custom
    }

    private static let compiledKeywords = AllergenKeywords.all.map(CompiledKeywords.init)

    private static func allergens(in words: Words) -> Set<Allergen> {
        Set(compiledKeywords.filter { $0.isFound(in: words) }.map(\.allergen))
    }

    private static func flag(_ trigger: AllergyFlag.Trigger, _ members: [MemberAllergies],
                             _ ingredients: [String]) -> AllergyFlag? {
        guard !members.isEmpty, !ingredients.isEmpty else { return nil }
        return AllergyFlag(trigger: trigger,
                           members: members.map { AllergyFlag.Member(id: $0.memberID, firstName: $0.firstName) },
                           ingredients: ingredients)
    }

    private struct CustomGroup {
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
            groups[key].map { CustomGroup(text: $0.text, phrase: Words(key).tokens, members: $0.members) }
        }
        .sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
    }

    private static func byFirstName(_ lhs: MemberAllergies, _ rhs: MemberAllergies) -> Bool {
        switch lhs.firstName.localizedStandardCompare(rhs.firstName) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.memberID.uuidString < rhs.memberID.uuidString
        }
    }

    private static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// A word in an ingredient name, with the spellings it could have as a singular, so "strawberries" meets
/// "strawberry" and "eggs" meets "egg". Deliberately naive English: good enough for grocery words, and
/// a rare over-match ("codes" meets "cod") is safer than a miss.
private struct Word: Sendable {
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
}

/// An ingredient name as whole words: case, accents, apostrophes, and punctuation folded away,
/// so "Shepherd's", "half-and-half", and "JALAPEÑO" all read like plain grocery words.
private struct Words: Sendable {
    let tokens: [Word]

    init(_ text: String) {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0 != "'" && $0 != "\u{2019}" }
        tokens = folded.split { !($0.isLetter || $0.isNumber) }.map { Word(String($0)) }
    }

    /// Where `phrase` starts, word for word.
    func occurrences(of phrase: [Word]) -> [Range<Int>] {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return [] }
        return (0...(tokens.count - phrase.count)).compactMap { start in
            let range = start..<(start + phrase.count)
            return zip(tokens[range], phrase).allSatisfy { $0.matches($1) } ? range : nil
        }
    }

    func contains(_ phrase: [Word]) -> Bool {
        !occurrences(of: phrase).isEmpty
    }
}

private struct CompiledKeywords: Sendable {
    let allergen: Allergen
    let phrases: [[Word]]
    let lookalikes: [[Word]]
    let freeFrom: [[Word]]

    private static let free = Word("free")

    init(_ keywords: AllergenKeywords) {
        allergen = keywords.allergen
        phrases = keywords.phrases.map { Words($0).tokens }
        lookalikes = keywords.lookalikes.map { Words($0).tokens }
        freeFrom = keywords.freeFrom.map { Words($0).tokens }
    }

    func isFound(in words: Words) -> Bool {
        guard !freeFrom.contains(where: words.contains) else { return false }
        let ruledOut = lookalikes.flatMap(words.occurrences)
        let hits = phrases.flatMap(words.occurrences).filter { hit in !ruledOut.contains { $0.overlaps(hit) } }
        let saysFree = hits.contains { hit in
            hit.upperBound < words.tokens.count && words.tokens[hit.upperBound].matches(Self.free)
        }
        return !hits.isEmpty && !saysFree
    }
}
