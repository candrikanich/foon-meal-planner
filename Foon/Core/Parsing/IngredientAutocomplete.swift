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
