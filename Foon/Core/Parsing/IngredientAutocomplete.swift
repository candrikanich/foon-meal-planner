/// Suggests household items while someone types an ingredient. Ranking: the exact item, then items
/// that start with what's typed, then items with a later word that does ("beef" finds "ground beef"),
/// each group alphabetical. Case and extra spaces never matter, and spellings of one item collapse
/// to the first one seen.
enum IngredientAutocomplete {
    static func suggestions(for prefix: String, from itemNames: [String], limit: Int = 5) -> [String] {
        let query = collapsed(prefix).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }

        var seen = Set<String>()
        let matches = itemNames.compactMap { name -> Match? in
            let display = collapsed(name)
            let key = display.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted, let rank = rank(of: key, for: query) else { return nil }
            return Match(rank: rank, key: key, display: display)
        }
        return matches
            .sorted { ($0.rank, $0.key) < ($1.rank, $1.key) }
            .prefix(limit)
            .map(\.display)
    }

    /// The ingredient being typed in a field that holds several ("1 lb ground beef, ta" → "ta"),
    /// without its quantity. Empty right after a separator, and inside an unclosed "(" (a size note).
    static func typing(in text: String) -> String {
        guard let fragment = lastFragment(of: text)?.fragment, !isOnlyQuantity(fragment),
              let parsed = IngredientParser.parse(String(fragment)).last
        else { return "" }
        return parsed.name
    }

    /// Suggestions for the ingredient being typed; none once it already matches an item exactly.
    static func suggestions(whileTyping text: String, from itemNames: [String], limit: Int = 5) -> [String] {
        let typed = typing(in: text)
        return suggestions(for: typed, from: itemNames, limit: limit)
            .filter { $0.caseInsensitiveCompare(collapsed(typed)) != .orderedSame }
    }

    /// Replaces the ingredient being typed with a suggestion, keeping its quantity, ready for the next one.
    static func completing(_ text: String, with suggestion: String) -> String {
        guard let (prefix, fragment) = lastFragment(of: text) else { return text }
        let leading = fragment.prefix { $0.isWhitespace }
        let quantity = IngredientParser.parse(String(fragment)).last?.quantity
        return prefix + leading + [quantity, suggestion].compactMap { $0 }.joined(separator: " ") + ", "
    }

    /// Splits where the parser does: commas, semicolons, bullets, and new lines outside parentheses.
    /// Nil while a "(" is still open, since the parser would read the rest as one ingredient.
    private static func lastFragment(of text: String) -> (prefix: String, fragment: Substring)? {
        var depth = 0
        var start = text.startIndex
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")": depth = max(depth - 1, 0)
            case ",", ";", "•" where depth == 0: start = text.index(after: index)
            case let character where depth == 0 && character.isNewline: start = text.index(after: index)
            default: break
            }
        }
        guard depth == 0 else { return nil }
        return (String(text[..<start]), text[start...])
    }

    /// "2 cups" or "1 1/2" with nothing after it yet: a quantity still waiting for its ingredient.
    /// A unit word alone ("can") is the start of a name ("canola oil").
    private static func isOnlyQuantity(_ fragment: Substring) -> Bool {
        let words = fragment.split(whereSeparator: \.isWhitespace)
        let isNumber = { (word: Substring) in word.allSatisfy { $0.isNumber || "./⁄-–".contains($0) } }
        return words.allSatisfy { isNumber($0) || IngredientParser.units.contains($0.lowercased()) }
            && (words.isEmpty || words.contains(where: isNumber))
    }

    private struct Match {
        let rank: Int
        let key: String
        let display: String
    }

    private static func rank(of key: String, for query: String) -> Int? {
        if key == query { return 0 }
        if key.hasPrefix(query) { return 1 }
        if key.contains(" " + query) { return 2 }
        return nil
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
