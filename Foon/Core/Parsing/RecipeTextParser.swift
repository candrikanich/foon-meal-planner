import Foundation

/// Turns recognized lines from a photo or PDF into a recipe (docs/spec.md → Share Sheet extension, photos and PDFs).
/// Plain code, no AI. When unsure a line stays an ingredient: allergy flags read ingredients only, so a wrong one is a
/// quick delete on the review screen, and a missing one is a missed flag. People check the result before saving.
enum RecipeTextParser {
    struct Capture: Equatable, Sendable {
        var name: String?
        var servings: Int?
        var ingredients: [ParsedIngredient] = []
        var steps: [String] = []

        var isEmpty: Bool { name == nil && ingredients.isEmpty && steps.isEmpty }
        /// More ingredients than a meal can hold: the review screen says so, since flags only read what's kept.
        var isTruncated: Bool { ingredients.count > ingredientLimit }

        /// Scaled to the family once, like a recipe from a link.
        func draft(householdSize: Int) -> MealDraft {
            let size = min(max(householdSize, 1), 50)
            let factor = servings.map { Double(size) / Double($0) } ?? 1
            var draft = MealDraft(newNamed: RecipeImport.clamped(name ?? "", to: 80))
            draft.servings = size
            draft.lines = ingredients.prefix(ingredientLimit).map {
                let quantity = $0.quantity.map { QuantityScaler.scale($0, by: factor) } ?? ""
                return MealDraft.Line(quantity: RecipeImport.clamped(quantity, to: 60),
                                      name: RecipeImport.ingredientName($0.name))
            }
            draft.stepsText = RecipeImport.clamped(steps.prefix(50).joined(separator: "\n"), to: stepsLimit)
            return draft
        }
    }

    /// What a meal can hold (`MealDraft.validated`), which also bounds the work on a long or hostile file.
    private static let stepsLimit = 20_000
    static let ingredientLimit = 60
    static let textLimit = 200_000
    private static let lineLimit = 2000

    private enum Section { case start, ingredients, steps, end }

    /// A social post's caption, if it holds a recipe: at least two ingredients, or it's better saved as an idea with its
    /// link. A caption often runs together ("Ingredients: 1 lb beef, 2 cups rice Directions: ..."), so its headers are
    /// put on their own lines. It's also decorated ("👇 INGREDIENTS") and selling something ("Comment CAESAR for the
    /// recipe"), and neither of those is an ingredient.
    static func parseCaption(_ caption: String) -> Capture? {
        let spaced = unwrappedInstagram(caption)
            .replacing(/(?i)\b(ingredients?|directions?|instructions?|method)\s*:/) { "\n\($0.1):\n" }
        var lines: [String] = []
        var ingredientLines: [String] = []
        var inIngredients = false
        var inSteps = false
        var sawIngredientsHeader = false
        for line in spaced.split(whereSeparator: \.isNewline).map(String.init) {
            let plain = withoutDecoration(line, trailing: true)
            // Only a hashtag that opens the line as written: "🥜 #1 peanut butter" is an ingredient.
            let opensWithHashtag = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            guard !plain.isEmpty, !opensWithHashtag, !isPromotion(plain) else { continue }
            if isIngredientsHeader(plain) || isStepsHeader(plain) {
                lines += splitItems(ingredientLines)
                ingredientLines = []
                inIngredients = isIngredientsHeader(plain)
                inSteps = !inIngredients
                sawIngredientsHeader = sawIngredientsHeader || inIngredients
                lines.append(plain)
                // "Ingredients (contains peanuts, shrimp)": a note like that may be the only place an allergen is named. Each
                // part keeps parentheses, so "(notes)" or "(nutrition info below)" can't read as the end of the recipe.
                if inIngredients, let note = plain.firstMatch(of: /\((.+)\)/)?.1 {
                    lines += note.split(separator: ",").map { part in
                        let words = part.trimmingCharacters(in: .whitespaces)
                        // "(serves 2)" still scales the amounts.
                        return servings(in: words) != nil ? words : "(\(words))"
                    }
                }
                continue
            }
            // Otherwise the emoji only comes off what's clearly an amount. Bared, "💡 Tip" would end the recipe, and "🥜 Makes
            // 2 cups peanut sauce" would be a servings line. A trailing one stays: "2 🥚" is an ingredient.
            let bared = withoutDecoration(line, trailing: false)
            var kept = isAmountLed(bared) ? bared : line
            if let keycap = keycapped(bared) {
                guard !keycap.rest.isEmpty else { continue }
                if inSteps { kept = "\(keycap.digit). \(keycap.rest)" }
                if inIngredients { kept = "\(keycap.digit) \(keycap.rest)" }
            }
            if inIngredients { ingredientLines.append(kept) } else { lines.append(kept) }
        }
        lines += splitItems(ingredientLines)
        var capture = parse(lines)
        // "Tag someone who loves tacos / Link in bio" would pass for a shopping list: a caption needs a header or amounts.
        let looksLikeARecipe = sawIngredientsHeader || capture.ingredients.count { $0.quantity != nil } >= 2
        capture.name = capture.name.map { withoutShouting(withoutDecoration($0, trailing: true)) }
        return looksLikeARecipe && capture.ingredients.count >= 2 ? capture : nil
    }

    /// Items split at commas, since a wrong extra line is a quick delete, a long merged one gets cut, and a merged one can
    /// hide an allergen ("gluten-free pasta, flour for dusting" reads as gluten-free). The exception is one amount with
    /// a plain description, short enough to keep whole. A section of one line is a list run together.
    private static func splitItems(_ section: [String]) -> [String] {
        section.flatMap { line -> [String] in
            let pieces = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // The matcher reads "plant-based" and "plant based" alike.
            let lower = line.lowercased().replacing("-", with: " ")
            // These labels apply to everything on an ingredient, so they'd cancel an allergen on the other side of the comma.
            let hasFreeFromLabel = lower.contains("free") || freeFromLabels.contains { lower.contains($0) }
            let isOneItem = section.count > 1 && pieces.count == 2 && isAmountLed(line) && !hasFreeFromLabel
                && MealDraft.length(line) <= maxWholeLine && isDescription(first: pieces[0], second: pieces[1])
            return isOneItem ? [line] : pieces
        }
    }

    /// "4 boneless, skinless chicken breasts" or "3 cloves garlic, finely minced".
    private static func isDescription(first: String, second: String) -> Bool {
        if let last = first.split(separator: " ").last, leadingDescriptions.contains(last.lowercased()) { return true }
        return second.split(separator: " ").allSatisfy { descriptions.contains($0.lowercased()) }
    }

    private static let leadingDescriptions: Set<String> = ["boneless", "skinless", "bone-in", "skin-on"]
    private static let descriptions: Set<String> = [
        "minced", "chopped", "diced", "sliced", "beaten", "melted", "softened", "peeled", "drained", "rinsed", "divided",
        "grated", "shredded", "cubed", "crushed", "thawed", "halved", "quartered", "toasted", "sifted", "packed", "optional",
        "finely", "roughly", "coarsely", "thinly", "freshly", "lightly", "room", "temperature", "at", "to", "taste",
    ]

    /// The allergy matcher's own labels, so the two can't drift apart.
    private static let freeFromLabels = AllergenKeywords.all.flatMap(\.freeFrom).map { $0.lowercased().replacing("-", with: " ") }

    /// `RecipeImport.ingredientName` cuts a longer name at its first comma.
    private static let maxWholeLine = 60

    /// Emoji and arrows off the start of a line, and optionally its end.
    private static func withoutDecoration(_ line: String, trailing: Bool) -> String {
        var text = Substring(line)
        func isDecoration(_ character: Character) -> Bool {
            guard let scalar = character.unicodeScalars.first else { return false }
            // Digits, "#", "*", "©" and the like count as emoji too.
            return character.isWhitespace || (scalar.properties.isEmoji && scalar.value > 0x238C)
                || (0x2190...0x21FF).contains(scalar.value)
        }
        while let first = text.first, isDecoration(first) { text.removeFirst() }
        while trailing, let last = text.last, isDecoration(last) { text.removeLast() }
        return String(text)
    }

    /// A line starting with a keycap "1️⃣": what it means depends on where it is, so it's only changed under a header.
    private static func keycapped(_ line: String) -> (digit: Character, rest: String)? {
        guard let first = line.first, first.unicodeScalars.contains("\u{20E3}"),
              let digit = first.unicodeScalars.first.map(Character.init) else { return nil }
        return (digit, line.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    /// A caption asking for something rather than saying how to cook. When unsure it stays, because a wrong ingredient is a
    /// quick delete and a dropped one is an allergy flag that never shows: a line that opens with an ask and has no number or
    /// list punctuation ("Comment PEANUT: 1 cup peanut butter" stays), or one that's nothing but a pointer to the recipe.
    private static func isPromotion(_ line: String) -> Bool {
        if line.wholeMatch(of: recipePointer) != nil { return true }
        return line.prefixMatch(of: ask) != nil && !line.contains(where: \.isNumber)
            && !line.contains(where: { ",;:•".contains($0) }) && !line.contains(" - ")
    }

    private static var ask: Regex<Substring> {
        /(?i)(?:comment\b|dm me\b|follow (?:me|us|for)\b|follow @|tag (?:a|your|someone)\b)/
    }

    private static var recipePointer: Regex<Substring> {
        /(?i)(?:link in (?:my )?bio|(?:(?:get|see|grab) )?(?:the )?(?:full )?recipe(?: (?:is )?(?:in|at) (?:my |the )?(?:bio|link)(?: in (?:my )?bio)?)?)[.!]*/
    }

    /// "SAVORY BAKED CHICKEN WITH SAUCE" reads as "Savory Baked Chicken with Sauce" in a list of dishes. A short name stays,
    /// since it may be an acronym: "BLT", "NY STRIP".
    private static func withoutShouting(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count >= 3, name == name.uppercased(), name != name.lowercased() else { return name }
        let small: Set<String> = ["a", "an", "and", "in", "of", "on", "or", "the", "with"]
        return words.enumerated().map { index, word in
            if word == "BBQ" { return String(word) }
            let lower = word.lowercased()
            if index > 0, small.contains(lower) { return lower }
            guard let letter = lower.firstIndex(where: \.isLetter) else { return lower }
            return lower[..<letter] + lower[letter].uppercased() + lower[lower.index(after: letter)...]
        }.joined(separator: " ")
    }

    /// Instagram's page wraps a caption as `12 likes, 3 comments - cook on June 1, 2026: "the caption".` Left on, the
    /// counts would pass for the dish's name.
    private static func unwrappedInstagram(_ caption: String) -> String {
        // A long caption is cut before its closing quote, and a post can hide its likes.
        let wrapped = /(?is)(?:[\d.,km]+ likes?, )?[\d.,km]+ comments? - .+?: ["“](.*?)["”]?\.?\s*/
        return caption.wholeMatch(of: wrapped).map { String($0.1) } ?? caption
    }

    static func parse(_ lines: [String]) -> Capture {
        var capture = Capture()
        var section = Section.start
        var sawHeader = false
        /// Short lines before anything else, in order: a recipe's name, or a shopping list.
        var loose: [String] = []

        var budget = textLimit
        for raw in lines.prefix(lineLimit) {
            if section == .end { break }
            // Counted in scalars, like `MealDraft.length`: a character can hold any number of them.
            let line = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(lineLimit)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            budget -= line.unicodeScalars.count
            if budget < 0 { break }
            if let servings = servings(in: line) {
                capture.servings = capture.servings ?? servings
                continue
            }
            if isNoise(line) { continue }
            if isEndHeader(line) {
                section = .end
            } else if isIngredientsHeader(line) {
                section = .ingredients
                sawHeader = true
            } else if isStepsHeader(line) {
                section = .steps
                sawHeader = true
            } else if isSubHeader(line), section != .steps {
                continue
            } else {
                switch section {
                case .start: start(line, &section, &capture, &loose)
                case .ingredients: ingredient(line, &section, &capture)
                case .steps: step(line, &capture)
                case .end: break
                }
            }
        }
        finish(&capture, loose: loose, sawHeader: sawHeader)
        return capture
    }

    /// No header yet: an amount or bullet is an ingredient, and a numbered or long line is a step only once there's
    /// something to cook. A long line before that is a blog's intro.
    private static func start(_ line: String, _ section: inout Section, _ capture: inout Capture, _ loose: inout [String]) {
        if startsAStep(line) {
            section = .steps
            step(line, &capture)
        } else if isAmountLed(line) {
            add(line, to: &capture)
        } else if line.count > longLine {
            if !capture.ingredients.isEmpty {
                section = .steps
                step(line, &capture)
            }
        } else if capture.ingredients.isEmpty {
            loose.append(line)
        } else {
            add(line, to: &capture)
        }
    }

    /// Under an Ingredients header only a Directions header or a real numbered step leaves. A long line stays: the
    /// cost of a wrong ingredient is a delete, and the cost of a misfiled one is an allergy flag that never shows.
    private static func ingredient(_ line: String, _ section: inout Section, _ capture: inout Capture) {
        if let number = line.firstMatch(of: numbered) {
            let rest = String(line[number.range.upperBound...])
            if isAmountLed(rest) || rest.count <= shortLine {
                add(rest, to: &capture)
            } else {
                section = .steps
                step(line, &capture)
            }
        } else if line.firstMatch(of: stepLabel) != nil {
            section = .steps
            step(line, &capture)
        } else {
            add(line, to: &capture)
        }
    }

    /// Recognition breaks a step wherever the line wrapped: a number or a "Step 2" starts one, and otherwise a line
    /// continues the last until that one has finished its sentence. In two columns, ingredients land between the steps.
    private static func step(_ line: String, _ capture: inout Capture) {
        if let label = line.firstMatch(of: numbered)?.range ?? line.firstMatch(of: stepLabel)?.range {
            // "Step 1" alone on its line: the text is on the next, so an empty step waits for it.
            capture.steps.append(String(line[label.upperBound...]))
            return
        }
        guard let last = capture.steps.last else {
            if isAmountLed(line), line.count <= shortLine { add(line, to: &capture) } else { capture.steps.append(line) }
            return
        }
        if last.isEmpty {
            capture.steps[capture.steps.count - 1] = line
        } else if !isFinished(last) {
            capture.steps[capture.steps.count - 1] = last + " " + line
        } else if isAmountLed(line), line.count <= shortLine {
            add(line, to: &capture)
        } else {
            capture.steps.append(line)
        }
    }

    private static func isFinished(_ step: String) -> Bool {
        step.hasSuffix(".") || step.hasSuffix("!") || step.hasSuffix("?")
    }

    /// With no headers and nothing to cook, short lines with no amounts are a shopping list; otherwise the first is the
    /// recipe's name.
    private static func finish(_ capture: inout Capture, loose: [String], sawHeader: Bool) {
        capture.steps.removeAll(where: \.isEmpty)
        let titled = loose.first.map { $0.wholeMatch(of: listTitle) != nil } ?? false
        let isList = !sawHeader && capture.steps.isEmpty && (titled || (capture.ingredients.isEmpty && loose.count >= 2))
        if isList {
            let items = (titled ? Array(loose.dropFirst()) : loose).compactMap(IngredientParser.parseLine)
            capture.ingredients = items + capture.ingredients
        } else {
            capture.name = loose.first { $0.count <= 80 }
            // When unsure, an ingredient: something between the name and the list may be one.
            let rest = capture.name == nil ? loose : Array(loose.dropFirst())
            capture.ingredients = rest.compactMap(IngredientParser.parseLine) + capture.ingredients
        }
    }

    private static func add(_ line: String, to capture: inout Capture) {
        if let ingredient = IngredientParser.parseLine(line) { capture.ingredients.append(ingredient) }
    }

    private static let longLine = 70
    private static let shortLine = 50
    private static var numbered: Regex<Substring> { /^\d{1,2}[.)]\s+/ }
    private static var stepLabel: Regex<Substring> { /(?i)^step\s+\d{1,2}\s*[:.]?\s*/ }
    private static var listTitle: Regex<(Substring, Substring)> { /(?i)(groceries|grocery list|shopping list|shopping|to buy)\s*:?/ }

    private static func startsAStep(_ line: String) -> Bool {
        line.firstMatch(of: numbered) != nil || line.firstMatch(of: stepLabel) != nil
    }

    /// "1 lb beef" or "2 cups" or "- salt"; a number then a capital ("30 Minute Chili") is a title.
    private static func isAmountLed(_ line: String) -> Bool {
        line.firstMatch(of: /^([-*•]\s|[¼½¾⅓⅔⅛]|\d+([.\/]\d+)?(\s*-\s*\d+)?\s*([¼½¾⅓⅔⅛]\s*)?[a-z(])/) != nil
    }

    private static func isIngredientsHeader(_ line: String) -> Bool {
        line.wholeMatch(of: /(?i)((the\s+)?ingredients?(\s*\(.*\))?|(what\s+)?you(['’]ll| will)\s+need)\s*:?/) != nil
    }

    private static func isStepsHeader(_ line: String) -> Bool {
        line.wholeMatch(of: /(?i)(directions?|instructions?|method|steps?|preparation|how to make( it)?)\s*:?/) != nil
    }

    /// Past these it isn't the recipe any more; Foon never keeps nutrition.
    private static func isEndHeader(_ line: String) -> Bool {
        line.wholeMatch(of: /(?i)(notes?|tips?|storage|nutrition(\s+.*)?)\s*:?/) != nil
    }

    private static func isSubHeader(_ line: String) -> Bool {
        // Only a label: "For the sauce: 2 tbsp peanut butter" has an ingredient on it.
        line.wholeMatch(of: /(?i)for the\b[^:]{0,40}:?/) != nil
    }

    private static func servings(in line: String) -> Int? {
        guard let match = line.wholeMatch(of: /(?i)(serves|servings?|yield|makes)\s*:?\s*(\d{1,2})\b.*/) else { return nil }
        return Int(match.2).flatMap { (1...50).contains($0) ? $0 : nil }
    }

    /// Screen chrome, ads, and page furniture.
    private static func isNoise(_ line: String) -> Bool {
        line.wholeMatch(of: /\d{1,2}:\d{2}(\s*[AaPp][Mm])?/) != nil                                    // the clock
            || line.wholeMatch(of: /\d+/) != nil                                                         // a page number
            || line.wholeMatch(of: /(?i)(5G|4G|LTE|Wi-?Fi|advertisement|sponsored|print|save|share)/) != nil
            || line.wholeMatch(of: /(?i)page\s+\d+(\s+of\s+\d+)?/) != nil
            || line.firstMatch(of: /(?i)^(https?:\/\/|www\.)|^[\w-]+\.(com|org|net|co)(\/\S*)?$/) != nil // a site
            || line.firstMatch(of: /(?i)\d(\.\d)?\s*stars?\b|\(\d+\s*reviews?\)/) != nil                  // a rating
            || line.firstMatch(of: /(?i)^(prep|cook|total|active)(\s+time)?\s*:?\s*\d/) != nil            // the times
    }
}
