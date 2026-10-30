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
            draft.stepsText = String(steps.prefix(50).joined(separator: "\n").prefix(stepsLimit))
            return draft
        }
    }

    /// What a meal can hold (`MealDraft.validated`), which also bounds the work on a long or hostile file.
    private static let stepsLimit = 20_000
    static let ingredientLimit = 60
    static let textLimit = 200_000
    private static let lineLimit = 2000

    private enum Section { case start, ingredients, steps, end }

    static func parse(_ lines: [String]) -> Capture {
        var capture = Capture()
        var section = Section.start
        var sawHeader = false
        /// Short lines before anything else, in order: a recipe's name, or a shopping list.
        var loose: [String] = []

        var budget = textLimit
        for raw in lines.prefix(lineLimit) {
            if section == .end { break }
            let line = String(raw.prefix(lineLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            budget -= line.count
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
