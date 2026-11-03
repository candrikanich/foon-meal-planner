import Foundation

/// Items from what someone said to Siri ("milk and eggs", "milk, eggs, and bread"). Dictation rarely puts a comma between
/// two things, so unlike typed quick add, " and " splits, except inside something the household already has ("mac and
/// cheese").
enum SpokenItems {
    static func names(_ text: String, known: Set<String>) -> [String] {
        IngredientParser.parse(text).flatMap { piece -> [String] in
            let name = piece.name.replacing(/^and\s+/.ignoresCase(), with: "")
            if known.contains(name.lowercased()) { return [name] }
            return name.split(separator: /\s+and\s+/.ignoresCase())
                .compactMap { IngredientParser.parseLine(String($0))?.name }
        }
        .filter { !$0.isEmpty }
    }
}
