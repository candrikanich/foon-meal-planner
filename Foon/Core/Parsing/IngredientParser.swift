/// One item typed into quick add: "1 lb ground beef" is name "ground beef", quantity "1 lb".
/// The quantity stays as typed; list merging and scaling interpret it later.
struct ParsedIngredient: Hashable, Sendable {
    let name: String
    let quantity: String?
}

/// Splits naturally typed ingredients ("1 lb ground beef, taco shells, cheese") into items.
///
/// Items break at commas, semicolons, newlines, and "•"; "-", "*" and "•" at a line start are bullets.
/// " and " never splits, because "mac and cheese" and "salt and pepper" are single items.
/// A quantity is only what the text says: a leading number (whole, decimal, 1/2, 1 1/2, ½, 1½, or a
/// range like 2-3), an optional unit, and a size in parentheses before or after the unit
/// ("1 (15 oz) can", "1 can (15 oz)").
/// "a"/"an" count only before a unit ("a dozen", "a can") or as "a few"/"a couple"; otherwise they
/// and "some" are dropped, since they carry no amount. "of" after a unit is dropped too.
enum IngredientParser {
    static func parse(_ text: String) -> [ParsedIngredient] {
        text.split(whereSeparator: \.isNewline)
            .flatMap { fragments(ofLine: $0.drop { $0.isWhitespace || bullets.contains($0) }) }
            .compactMap(cleaned)
            .map(ingredient)
    }

    private static let bullets: Set<Character> = ["-", "*", "•"]
    private static let separators: Set<Character> = [",", ";", "•"]
    private static let fractions: Set<Character> = ["½", "¼", "¾", "⅓", "⅔", "⅛", "⅜", "⅝", "⅞"]
    private static let fractionSlashes: Set<Character> = ["/", "⁄"]
    private static let rangeDashes: Set<Character> = ["-", "–"]
    /// Matched case-insensitively, so recipe shorthand "T" (tablespoon) vs "t" (teaspoon) and "c"
    /// (cup) are left out: guessing between them would invent an amount.
    static let units: Set<String> = [
        "lb", "lbs", "pound", "pounds", "oz", "ounce", "ounces", "g", "kg", "ml", "l",
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
        "can", "cans", "jar", "jars", "bag", "bags", "box", "boxes",
        "pack", "packs", "package", "packages", "bottle", "bottles", "clove", "cloves",
        "bunch", "bunches", "head", "heads", "pint", "pints", "dozen",
        "slice", "slices", "stick", "sticks", "pinch",
        "loaf", "loaves", "carton", "cartons", "packet", "packets", "stalk", "stalks",
        "gallon", "gallons", "gal", "quart", "quarts", "qt", "pt", "pkg",
        "container", "containers", "piece", "pieces"
    ]

    /// Separators inside parentheses don't split, so "1 (14.5 oz, diced) can" stays whole. An
    /// unclosed parenthesis would swallow the rest of the line, so then parentheses are ignored.
    private static func fragments(ofLine line: Substring) -> [Substring] {
        let depthAware = split(line, respectingParentheses: true)
        return depthAware.balanced ? depthAware.parts : split(line, respectingParentheses: false).parts
    }

    private static func split(_ line: Substring, respectingParentheses: Bool) -> (parts: [Substring], balanced: Bool) {
        var parts: [Substring] = []
        var start = line.startIndex
        var depth = 0
        for index in line.indices {
            switch line[index] {
            case "(" where respectingParentheses: depth += 1
            case ")" where respectingParentheses: depth = max(0, depth - 1)
            case let character where depth == 0 && separators.contains(character):
                parts.append(line[start..<index])
                start = line.index(after: index)
            default: break
            }
        }
        parts.append(line[start...])
        return (parts, depth == 0)
    }

    private static func cleaned(_ fragment: Substring) -> String? {
        var text = fragment.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while text.last == "." || text.last == " " { text.removeLast() }
        return text.contains { $0.isLetter || $0.isNumber } ? text : nil
    }

    /// When nothing is left after the quantity ("2 cups"), the whole text is the name: better to
    /// keep what was typed than to drop it.
    private static func ingredient(from fragment: String) -> ParsedIngredient {
        let (quantity, name) = wordQuantity(fragment) ?? numericQuantity(fragment) ?? (nil, fragment)
        guard !name.isEmpty else { return ParsedIngredient(name: fragment, quantity: nil) }
        return ParsedIngredient(name: name, quantity: quantity)
    }

    private static func wordQuantity(_ fragment: String) -> (String?, String)? {
        let words = fragment.split(separator: " ")
        guard let first = words.first?.lowercased() else { return nil }
        if first == "some" { return (nil, words.dropFirst().joined(separator: " ")) }
        guard first == "a" || first == "an" else { return nil }
        guard words.count > 1, isUnit(words[1]) || ["few", "couple"].contains(words[1].lowercased()) else {
            return (nil, words.dropFirst().joined(separator: " "))
        }
        let rest = words.dropFirst(2)
        let name = rest.first?.lowercased() == "of" ? rest.dropFirst() : rest
        return (words.prefix(2).joined(separator: " "), name.joined(separator: " "))
    }

    private static func numericQuantity(_ fragment: String) -> (String?, String)? {
        let chars = Array(fragment)
        guard var end = number(in: chars, at: 0) else { return nil }
        if let rangeEnd = rangeEnd(in: chars, after: end) { end = rangeEnd }

        var hasUnit = false
        if end < chars.count, chars[end].isLetter {
            guard let unitEnd = unitEnd(in: chars, at: end) else { return nil }
            (end, hasUnit) = (unitEnd, true)
        } else if end < chars.count, chars[end] == " " {
            if let sizeEnd = parentheticalSizeEnd(in: chars, at: end + 1) { end = sizeEnd }
            if end < chars.count, chars[end] == " ", let unitEnd = unitEnd(in: chars, at: end + 1) {
                (end, hasUnit) = (unitEnd, true)
            }
        } else if end < chars.count {
            return nil
        }
        if hasUnit, end < chars.count, chars[end] == " ",
           let sizeEnd = parentheticalSizeEnd(in: chars, at: end + 1) {
            end = sizeEnd
        }

        let quantity = String(chars[..<end])
        let rest = chars[end...].split(separator: " ")
        let name = hasUnit && rest.first.map({ String($0).lowercased() }) == "of" ? rest.dropFirst() : rest[...]
        return (quantity, name.map { String($0) }.joined(separator: " "))
    }

    /// Returns where a number starting at `start` ends: 2, 1.5, 1/2, ½, 1½, 1 1/2, or 1 ½.
    private static func number(in chars: [Character], at start: Int) -> Int? {
        guard start < chars.count else { return nil }
        if fractions.contains(chars[start]) { return start + 1 }
        let wholeEnd = digitsEnd(in: chars, from: start)
        guard wholeEnd > start else { return nil }
        guard wholeEnd < chars.count else { return wholeEnd }

        let next = chars[wholeEnd]
        if next == ".", digitsEnd(in: chars, from: wholeEnd + 1) > wholeEnd + 1 {
            return digitsEnd(in: chars, from: wholeEnd + 1)
        }
        if fractionSlashes.contains(next), digitsEnd(in: chars, from: wholeEnd + 1) > wholeEnd + 1 {
            return digitsEnd(in: chars, from: wholeEnd + 1)
        }
        if fractions.contains(next) { return wholeEnd + 1 }
        if next == " " { return mixedFractionEnd(in: chars, at: wholeEnd + 1) ?? wholeEnd }
        return wholeEnd
    }

    private static func mixedFractionEnd(in chars: [Character], at start: Int) -> Int? {
        guard start < chars.count else { return nil }
        if fractions.contains(chars[start]) { return start + 1 }
        let numeratorEnd = digitsEnd(in: chars, from: start)
        guard numeratorEnd > start, numeratorEnd < chars.count, fractionSlashes.contains(chars[numeratorEnd]) else {
            return nil
        }
        let denominatorEnd = digitsEnd(in: chars, from: numeratorEnd + 1)
        return denominatorEnd > numeratorEnd + 1 ? denominatorEnd : nil
    }

    /// "2-3", "2 - 3", "2–3". A dash not followed by a number ("3-bean") isn't a range.
    private static func rangeEnd(in chars: [Character], after end: Int) -> Int? {
        var index = end
        if index < chars.count, chars[index] == " " { index += 1 }
        guard index < chars.count, rangeDashes.contains(chars[index]) else { return nil }
        index += 1
        if index < chars.count, chars[index] == " " { index += 1 }
        return number(in: chars, at: index)
    }

    /// "(15 oz)" belongs to the quantity only when it holds a number and stands as its own word;
    /// "(optional)" stays with the name.
    private static func parentheticalSizeEnd(in chars: [Character], at start: Int) -> Int? {
        guard start < chars.count, chars[start] == "(",
              let close = chars[start...].firstIndex(of: ")"),
              chars[start...close].contains(where: \.isNumber),
              close + 1 == chars.count || chars[close + 1] == " " else { return nil }
        return close + 1
    }

    /// A unit word, optionally abbreviated with a period ("oz."), ending at a word boundary.
    private static func unitEnd(in chars: [Character], at start: Int) -> Int? {
        var end = start
        while end < chars.count, chars[end].isLetter { end += 1 }
        guard end > start, units.contains(String(chars[start..<end]).lowercased()) else { return nil }
        if end < chars.count, chars[end] == "." { end += 1 }
        return end == chars.count || chars[end] == " " ? end : nil
    }

    private static func isUnit(_ word: Substring) -> Bool {
        let lowered = word.lowercased()
        return units.contains(lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered)
    }

    private static func digitsEnd(in chars: [Character], from start: Int) -> Int {
        var end = start
        while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
        return end
    }
}
