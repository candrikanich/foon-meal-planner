import Foundation

/// One of the household's items, as the matcher sees it.
struct ReceiptItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// A receipt line the family taught: this text (as `ReceiptMatcher.key` reads it) is this item (`receipt_aliases`).
struct ReceiptAlias: Codable, Equatable, Hashable, Sendable {
    let rawText: String
    let itemID: UUID

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case itemID = "item_id"
    }
}

/// Reads receipt text into lines that are groceries, each with the household item it most likely is (docs/spec.md →
/// Receipts). Deterministic and on the device: prices, totals, tax, card, store and address lines, and quantity and
/// weight lines go; what the family taught comes first; then receipt shorthand is spelled out and compared word by word.
enum ReceiptMatcher {
    /// Below this a line is listed under "Didn't recognize" rather than guessed.
    static let threshold = 0.6
    /// `receipt_aliases.raw_text` holds at most this much.
    static let keyLimit = 80

    struct Match: Equatable, Sendable {
        let itemID: UUID
        /// 0 to 1: 1 for a learned line or the item's own name.
        let confidence: Double
        /// From a correction the family made, rather than the words.
        let learned: Bool
    }

    struct Line: Identifiable, Equatable, Sendable {
        /// Its place among the lines, in receipt order.
        let id: Int
        /// The line as printed, without prices, codes and flags: "BNLS CHKN BRST".
        let text: String
        /// What a correction is saved under.
        let key: String
        let match: Match?
    }

    struct Candidate: Equatable, Sendable {
        let text: String
        let key: String
        let words: [String]
        /// The line carried a price, so the item lines have started.
        let priced: Bool
    }

    static func match(_ lines: [String], items: [ReceiptItem], aliases: [ReceiptAlias]) -> [Line] {
        let candidates = candidates(lines)
        let known = Set(items.map(\.id))
        let learned = Dictionary(aliases.filter { known.contains($0.itemID) }.map { ($0.rawText, $0.itemID) },
                                 uniquingKeysWith: { first, _ in first })
        // Sorted, so a tie goes the same way whatever order the items came in.
        let readable = items
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
            .map { (id: $0.id, words: ReceiptText.words($0.name)) }
        // A store's name, slogan and address come before its first priced line, and match nothing. With no priced line at
        // all (Vision read the prices as a column of their own), there's no telling where the items start, so all stay.
        let firstPriced = candidates.firstIndex(where: \.priced)
        var result: [Line] = []
        for (index, candidate) in candidates.enumerated() {
            let found = learned[candidate.key].map { Match(itemID: $0, confidence: 1, learned: true) }
                ?? best(candidate.words, among: readable)
            if found == nil, let firstPriced, index < firstPriced { continue }
            result.append(Line(id: result.count, text: candidate.text, key: candidate.key, match: found))
        }
        return result
    }

    /// The lines that could be groceries, in order, up to the total.
    static func candidates(_ lines: [String]) -> [Candidate] {
        var result: [Candidate] = []
        for line in lines {
            let upper = line.uppercased()
            let ordered = upper.split { !$0.isLetter }.map(String.init)
            let words = Set(ordered)
            if endsReceipt(ordered) { break }
            guard !isNoise(upper, words: words), let text = printed(line) else { continue }
            let readable = ReceiptText.words(text)
            guard !readable.isEmpty else { continue }
            result.append(Candidate(text: text, key: aliasKey(text), words: readable,
                                    priced: contains(line, pattern: price)))
        }
        return result
    }

    /// What a correction is saved under: the line as printed, lowercased, without prices, codes and flags.
    static func key(_ line: String) -> String? {
        printed(line).map(aliasKey)
    }

    /// Trimmed after the cut, the way the server stores it, so a cut that lands on a space still finds its alias.
    private static func aliasKey(_ text: String) -> String {
        String(text.lowercased().prefix(keyLimit)).trimmingCharacters(in: .whitespaces)
    }

    /// "TOTAL 37.85" and "BALANCE DUE" end the receipt; "GM TOTAL CEREAL" and "BALANCE BAR" are groceries.
    private static func endsReceipt(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if words.count > 1, totalPrefixes.contains(first), words[1] == "TOTAL" { return true }
        return endWords.contains(first) && words.dropFirst().allSatisfy(endTrailers.contains)
    }

    /// 0.6 for covering the item's words, 0.4 for covering the line's: "CHOBANI YGRT" is yogurt, and a line with every
    /// word of "Box mac and cheese" beats one with only "cheese".
    static func score(_ line: [String], _ item: [String]) -> Double {
        guard !line.isEmpty, !item.isEmpty else { return 0 }
        let itemCover = item.map { word in line.map { ReceiptText.likeness($0, word) }.max() ?? 0 }.reduce(0, +)
        let lineCover = line.map { word in item.map { ReceiptText.likeness(word, $0) }.max() ?? 0 }.reduce(0, +)
        let score = 0.6 * itemCover / Double(item.count) + 0.4 * lineCover / Double(line.count)
        return (score * 100).rounded() / 100
    }

    private static func best(_ words: [String], among items: [(id: UUID, words: [String])]) -> Match? {
        var best: (id: UUID, score: Double)?
        for item in items {
            let score = score(words, item.words)
            if score > (best?.score ?? 0) { best = (item.id, score) }
        }
        guard let best, best.score >= threshold else { return nil }
        return Match(itemID: best.id, confidence: best.score, learned: false)
    }

    // MARK: - Reading a line

    /// The line's words as printed, without prices, codes, weights and the tax flags after a price. Nil when nothing's left.
    private static func printed(_ line: String) -> String? {
        let kept = line.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "&'")))
            let letters = trimmed.lowercased().filter(\.isLetter)
            guard !trimmed.contains(where: \.isNumber), letters.count >= 2, !printedNoise.contains(letters) else { return nil }
            return trimmed
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    private static func isNoise(_ upper: String, words: Set<String>) -> Bool {
        if upper.contains("#") || upper.contains("**") { return true }
        if !words.isDisjoint(with: noiseWords) { return true }
        if !words.isEmpty, words.isSubset(of: departments) { return true }
        return noisePatterns.contains { contains(upper, pattern: $0) }
    }

    /// From here on it's the payment.
    private static let endWords: Set<String> = ["TOTAL", "SUBTOTAL", "BALANCE"]
    private static let totalPrefixes: Set<String> = ["SUB", "GRAND", "ORDER"]
    private static let endTrailers: Set<String> = ["DUE", "AMOUNT", "AMT", "USD", "SALE", "PURCHASE", "OWED", "TO", "PAY", "TODAY"]

    private static let noiseWords: Set<String> = [
        "TAX", "CHANGE", "CASH", "VISA", "MASTERCARD", "AMEX", "DISCOVER", "DEBIT", "CREDIT", "CARD", "TEND", "TENDER",
        "AUTH", "APPROVAL", "APPROVED", "REF", "TERMINAL", "TRANSACTION", "CASHIER", "MANAGER", "STORE", "THANK", "THANKS",
        "SAVE", "SAVED", "SAVINGS", "COUPON", "COUPONS", "REWARDS", "POINTS", "MEMBER", "CUSTOMER", "ITEMS", "SOLD",
        "RECEIPT", "SURVEY", "PAYMENT", "PURCHASE", "AID", "ACCOUNT", "REG", "DUE", "DIR", "DAILY", "PHONE", "TEL", "WWW",
        "HTTP", "HTTPS", "RETURN", "RETURNS", "POLICY", "SIGNATURE", "LOYALTY", "VOID", "REFUND"
    ]

    /// A heading over a receipt's section ("PRODUCE"), when it's all the line says.
    private static let departments: Set<String> = [
        "PRODUCE", "GROCERY", "GROCERIES", "MEAT", "MEATS", "SEAFOOD", "DELI", "BAKERY", "DAIRY", "FROZEN", "HOME",
        "HOUSEHOLD", "HEALTH", "BEAUTY", "GENERAL", "MERCHANDISE", "PHARMACY", "FLORAL", "BEVERAGES", "SNACKS",
        "REFRIGERATED", "PANTRY", "FOOD", "FOODS", "CLEANING", "PERSONAL", "CARE", "PET", "PETS"
    ]

    /// Printed beside an item, never part of its name: weights and the tax flags chains print after a price.
    private static let printedNoise: Set<String> = ["lb", "lbs", "oz", "kg", "nf", "kf", "fs", "tf", "ea"]

    // Patterns as text: Regex isn't Sendable, so it can't be a static constant.
    private static let price = #"\$?\d+\.\d{2}(?!\d)"#
    /// Phone numbers, dates, times, a street address, and a city, state and ZIP.
    private static let noisePatterns = [
        #"\(?\s*\d{3}\s*\)?\s*[-.]?\s*\d{3}\s*[-.]\s*\d{4}"#,
        #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
        #"\b\d{1,2}:\d{2}"#,
        #"^\s*\d+\s+.*\b(?:ST|AVE|RD|BLVD|DR|LN|WAY|HWY|PKWY|CT|PL|STREET|AVENUE|ROAD)\.?\s*$"#,
        #"\b[A-Z]{2}\s+\d{5}(?:-\d{4})?\s*$"#
    ]

    private static func contains(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
