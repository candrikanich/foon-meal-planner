import Foundation

/// How a receipt line and an item name are read for matching: receipt shorthand spelled out, plurals made singular, and
/// words that say nothing about which item it is (brands, sizes, "organic") left out. Both sides go through the same steps,
/// so "BNLS CHKN BRST" and "Chicken breasts" meet as `chicken breast`.
enum ReceiptText {
    static func words(_ text: String) -> [String] {
        let raw = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen = Set<String>()
        return raw
            .filter { $0.count >= 2 && !$0.contains(where: \.isNumber) }
            .flatMap { abbreviations[$0]?.split(separator: " ").map(String.init) ?? [$0] }
            .map(singular)
            .filter { !ignored.contains($0) && seen.insert($0).inserted }
    }

    /// "strawberries" → "strawberry", "tomatoes" → "tomato", "eggs" → "egg". Rough, but applied to both sides alike.
    static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if ["ches", "shes", "sses", "xes"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }

    /// Shorthand the US chains print that the subsequence rule can't place (too short, or letters it lacks), plus the
    /// most common ones, so they match exactly rather than nearly.
    static let abbreviations: [String: String] = [
        "bnls": "boneless", "bls": "boneless", "sknls": "skinless", "chkn": "chicken", "chk": "chicken", "ckn": "chicken",
        "brst": "breast", "bst": "breast", "thgh": "thigh", "grnd": "ground", "grd": "ground", "bf": "beef", "trky": "turkey",
        "prk": "pork", "saus": "sausage", "bcn": "bacon", "whl": "whole", "wh": "whole", "mlk": "milk", "skm": "skim",
        "chs": "cheese", "chz": "cheese", "chdr": "cheddar", "ched": "cheddar", "mozz": "mozzarella", "parm": "parmesan",
        "shrd": "shredded", "ygrt": "yogurt", "yog": "yogurt", "btr": "butter", "bttr": "butter", "crm": "cream",
        "crmy": "creamy", "pb": "peanut butter", "jly": "jelly", "brd": "bread", "ww": "whole wheat", "bgl": "bagel",
        "tort": "tortilla", "crl": "cereal", "pza": "pizza", "oj": "orange juice", "jc": "juice", "jce": "juice",
        "org": "organic", "orgnc": "organic", "yel": "yellow", "wht": "white", "grn": "green", "tom": "tomato",
        "lett": "lettuce", "rom": "romaine", "broc": "broccoli", "cuc": "cucumber", "avo": "avocado",
        "bnna": "banana", "ppr": "paper", "twl": "towel", "tp": "toilet paper", "det": "detergent", "dtrg": "detergent",
        "wtr": "water", "cof": "coffee", "flr": "flour", "sgr": "sugar", "olv": "olive", "veg": "vegetable",
        "sce": "sauce", "pst": "pasta", "spag": "spaghetti", "bns": "beans", "blk": "black", "crkr": "cracker",
        "chps": "chip"
    ]

    /// Words that don't say which item it is: store brands, sizes and packaging, and the usual descriptions.
    static let ignored: Set<String> = [
        // Store brands and chains.
        "gv", "ks", "kirkland", "kro", "kroger", "gg", "sig", "signature", "mm", "wfm", "pc", "hmr", "walmart", "target",
        "costco", "safeway", "publix", "aldi", "heb", "meijer", "wegmans", "tj", "tjs",
        // Sizes, counts, units, packaging.
        "lb", "lbs", "oz", "fl", "ct", "pk", "pack", "ea", "each", "gal", "gallon", "qt", "pt", "dz", "dozen", "lg", "large",
        "sm", "small", "med", "medium", "xl", "jumbo", "family", "fam", "size", "sz", "bag", "bg", "box", "bx", "btl",
        "bottle", "jar", "value", "wt", "net",
        // Descriptions.
        "organic", "fresh", "natural", "nat", "premium", "prem", "select", "original", "orig", "classic", "plain",
        "boneless", "skinless", "frozen", "frzn", "baby", "salted", "unsalted", "hass",
        // Joining words in item names.
        "and", "the", "of", "with", "in", "nf", "kf", "fs", "tf"
    ]

    /// How alike two words are, 0 to 1: the same, one the start of the other ("spag", "spaghetti"), one slip in reading
    /// ("banannas"), or a receipt's shorthand that keeps the word's letters in order ("strwbry", "strawberry").
    static func likeness(_ receipt: String, _ item: String) -> Double {
        if receipt == item { return 1 }
        let shorter = min(receipt.count, item.count)
        // A receipt cuts words short; the other way round only a plural ending, or "applesauce" would read as apples.
        if shorter >= 4, item.hasPrefix(receipt) || (receipt.hasPrefix(item) && receipt.count - item.count <= 2) {
            return 0.9
        }
        if shorter >= 5, editDistance(receipt, item, limit: 1) <= 1 { return 0.85 }
        if receipt.count >= 3, receipt.count < item.count, receipt.first == item.first, isSubsequence(receipt, of: item) {
            return 0.8
        }
        return 0
    }

    private static func isSubsequence(_ short: String, of long: String) -> Bool {
        var remaining = Substring(long)
        for character in short {
            guard let found = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }

    /// Levenshtein distance, giving up once it's past `limit`.
    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            guard (current.min() ?? 0) <= limit else { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
