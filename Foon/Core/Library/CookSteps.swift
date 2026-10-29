import Foundation

/// Timers hidden in recipe steps ("simmer 30 minutes", "bake for 1 1/2 hours", "rest 20-25 min"), for cook mode's
/// one-tap timers. A range starts at its low end, so the cook checks early; "1 hour 30 minutes" is one timer. Pure.
enum CookSteps {
    struct Timer: Equatable, Sendable {
        let seconds: Int
        /// The words that set it ("30 minutes"), shown on the timer button.
        let label: String
    }

    /// One "amount unit" in the text, before ranges across units and combined times are merged.
    private struct Match {
        let seconds: Int
        let unit: Unit
        let range: Range<String.Index>
    }

    private enum Unit {
        case hours, minutes, seconds

        var seconds: Double {
            switch self {
            case .hours: 3600
            case .minutes: 60
            case .seconds: 1
            }
        }
    }

    private static let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75]

    static func timers(in step: String) -> [Timer] {
        let amount = #"(?:\d+(?:[.,]\d+)?(?:\s+\d\/\d|[½¼¾])?|\d\/\d|[½¼¾]|an?)"#
        let pattern = #"(?i)\b("# + amount + #")(?:\s*(?:-|–|to)\s*"# + amount + #")?\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#
        guard let regex = try? Regex(pattern) else { return [] }
        let matches: [Match] = step.matches(of: regex).compactMap { match in
            guard let amountText = match.output[1].substring, let unitText = match.output[2].substring,
                  let value = Self.amount(String(amountText)), value > 0 else { return nil }
            let unit: Unit = switch unitText.lowercased().first {
            case "h": .hours
            case "m": .minutes
            default: .seconds
            }
            let seconds = Int((value * unit.seconds).rounded())
            guard (1...(24 * 3600)).contains(seconds) else { return nil }
            return Match(seconds: seconds, unit: unit, range: match.range)
        }
        return merged(matches, in: step).map { seconds, range in
            Timer(seconds: seconds, label: String(step[range]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// "1 hour 30 minutes" (or "1 hour and 30 minutes") adds up to one timer; "45 min-1 hour" is a range that starts at
    /// its low end.
    private static func merged(_ matches: [Match], in step: String) -> [(Int, Range<String.Index>)] {
        var result: [(seconds: Int, unit: Unit, range: Range<String.Index>)] = []
        for match in matches {
            if let last = result.last {
                let gap = step[last.range.upperBound..<match.range.lowerBound].lowercased()
                    .trimmingCharacters(in: .whitespaces)
                if last.unit == .hours, match.unit == .minutes, gap.isEmpty || gap == "and" {
                    result[result.count - 1] = (last.seconds + match.seconds, .minutes,
                                                last.range.lowerBound..<match.range.upperBound)
                    continue
                }
                if ["-", "–", "to"].contains(gap) {
                    result[result.count - 1] = (min(last.seconds, match.seconds), last.unit,
                                                last.range.lowerBound..<match.range.upperBound)
                    continue
                }
            }
            result.append((match.seconds, match.unit, match.range))
        }
        return result.map { ($0.seconds, $0.range) }
    }

    private static func amount(_ text: String) -> Double? {
        let lower = text.lowercased()
        if lower == "a" || lower == "an" { return 1 }
        var total = 0.0
        for part in lower.replacingOccurrences(of: ",", with: ".").split(separator: " ") {
            var part = Substring(part)
            if let last = part.last, let fraction = fractions[last] {
                total += fraction
                part = part.dropLast()
                if part.isEmpty { continue }
            }
            if part.contains("/") {
                let pieces = part.split(separator: "/").compactMap { Double($0) }
                guard pieces.count == 2, pieces[1] != 0 else { return nil }
                total += pieces[0] / pieces[1]
            } else {
                guard let value = Double(part) else { return nil }
                total += value
            }
        }
        return total
    }

    /// "4:05" or "1:02:30", for a timer's countdown.
    static func clock(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let (hours, minutes, rest) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// "4 minutes, 5 seconds", for VoiceOver.
    static func spoken(_ seconds: Int) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
