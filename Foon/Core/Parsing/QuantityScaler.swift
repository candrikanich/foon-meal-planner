import Foundation

/// Scales the amount at the start of a quantity ("1 1/2 cups", "1-1/2 cups", "½ tsp", "2-3 cloves") and keeps the rest
/// as written.
/// Anything without a leading number ("a dozen", "to taste") is left alone: there's no amount to scale.
enum QuantityScaler {
    static func scale(_ quantity: String, by factor: Double) -> String {
        guard factor > 0, abs(factor - 1) > 0.001 else { return quantity }
        let chars = Array(quantity)
        guard let (scaled, end) = leading(chars, by: factor) else { return quantity }
        return scaled + String(chars[end...])
    }

    /// For a shopping amount, where a wrong number means the wrong thing bought: only one amount and what it counts, with
    /// a package size in brackets allowed ("1 (15 oz) can"). Anything else with a number in it ("1 to 2 lb", "2 lb 8 oz",
    /// "1/2 cup + 2 tbsp") returns nil, because scaling the start alone would state something false.
    static func scaledIfSimple(_ quantity: String, by factor: Double) -> String? {
        let chars = Array(quantity)
        guard let (scaled, end) = leading(chars, by: factor) else { return nil }
        var depth = 0
        for character in chars[end...] {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(depth - 1, 0) }
            if depth == 0, character.isNumber { return nil }
        }
        return scaled + String(chars[end...])
    }

    /// The scaled amount at the start, and where it ends.
    private static func leading(_ chars: [Character], by factor: Double) -> (String, Int)? {
        guard let (first, firstEnd) = amount(in: chars, at: 0) else { return nil }
        var end = firstEnd
        var scaled = format(first * factor)
        if end < chars.count, rangeDashes.contains(chars[end]), let (second, secondEnd) = amount(in: chars, at: end + 1) {
            if second < 1, first == first.rounded() {
                // "1-1/2" is how some sites write one and a half, not a range from 1 down to 1/2.
                scaled = format((first + second) * factor)
            } else {
                scaled += "-" + format(second * factor)
            }
            end = secondEnd
        }
        return (scaled, end)
    }

    private static let rangeDashes: Set<Character> = ["-", "–"]
    private static let unicodeFractions: [Character: Double] = [
        "½": 1 / 2, "¼": 1 / 4, "¾": 3 / 4, "⅓": 1 / 3, "⅔": 2 / 3, "⅛": 1 / 8, "⅜": 3 / 8, "⅝": 5 / 8, "⅞": 7 / 8
    ]

    /// 2, 1.5, 1/2, ½, 1½, 1 1/2, 1 ½: the value and where it ends.
    private static func amount(in chars: [Character], at start: Int) -> (Double, Int)? {
        guard start < chars.count else { return nil }
        if let fraction = unicodeFractions[chars[start]] { return (fraction, start + 1) }
        guard let (whole, wholeEnd) = digits(in: chars, at: start) else { return nil }
        guard wholeEnd < chars.count else { return (whole, wholeEnd) }
        switch chars[wholeEnd] {
        case "." where digits(in: chars, at: wholeEnd + 1) != nil:
            let decimalEnd = digits(in: chars, at: wholeEnd + 1)!.1
            return (Double(String(chars[start..<decimalEnd])) ?? whole, decimalEnd)
        case "/", "⁄":
            guard let (denominator, end) = digits(in: chars, at: wholeEnd + 1), denominator > 0 else { return (whole, wholeEnd) }
            return (whole / denominator, end)
        case let character where unicodeFractions[character] != nil:
            return (whole + unicodeFractions[character]!, wholeEnd + 1)
        case " ":
            if wholeEnd + 1 < chars.count, let fraction = unicodeFractions[chars[wholeEnd + 1]] {
                return (whole + fraction, wholeEnd + 2)
            }
            if let (numerator, numeratorEnd) = digits(in: chars, at: wholeEnd + 1), numeratorEnd < chars.count,
               chars[numeratorEnd] == "/", let (denominator, end) = digits(in: chars, at: numeratorEnd + 1),
               denominator > 0 {
                return (whole + numerator / denominator, end)
            }
            return (whole, wholeEnd)
        default:
            return (whole, wholeEnd)
        }
    }

    private static func digits(in chars: [Character], at start: Int) -> (Double, Int)? {
        var end = start
        while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
        guard end > start, let value = Double(String(chars[start..<end])) else { return nil }
        return (value, end)
    }

    /// Kitchen-friendly: whole numbers and common fractions ("1 1/2", "3/4"), else one decimal place.
    static func format(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let rest = value - whole
        let fractions: [(Double, String)] = [(0, ""), (1 / 8, "1/8"), (1 / 4, "1/4"), (1 / 3, "1/3"), (1 / 2, "1/2"),
                                             (2 / 3, "2/3"), (3 / 4, "3/4"), (1, "")]
        if let (fraction, text) = fractions.first(where: { abs(rest - $0.0) < 0.04 }) {
            let wholePart = Int(whole + (fraction == 1 ? 1 : 0))
            // A pinch of cayenne scaled down is still some cayenne, never "0".
            if wholePart == 0, text.isEmpty { return value > 0 ? "1/8" : "0" }
            if text.isEmpty { return String(wholePart) }
            return wholePart == 0 ? text : "\(wholePart) \(text)"
        }
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
