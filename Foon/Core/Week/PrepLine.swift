import Foundation

/// The one line on a night's card for getting ready to cook (docs/spec.md → Cooking start time): the first prep step
/// and the cook window, "Thaw the chicken · 1 day ahead · Cook 3:00–6:00 PM". Either half stands alone; with neither
/// there's no line. `spoken` is the sentence VoiceOver reads, since a dash between two times reads badly.
struct PrepLine: Equatable, Hashable, Sendable {
    let text: String
    let spoken: String

    init(_ text: String, spoken: String? = nil) {
        self.text = text
        self.spoken = spoken ?? text
    }

    /// Before noon the range would run from morning to evening and be easy to misread at a glance, so it says only
    /// when cooking starts. (`StartCooking` never starts the day before, so there's no day to name.)
    static let earlyStartMinute = 12 * 60

    static func make(prep: String?, start: StartCooking?, locale: Locale = .current) -> PrepLine? {
        switch (prep, start) {
        case (nil, nil): nil
        case (let prep?, nil): PrepLine(prep)
        case (nil, let start?): PrepLine(window(start, locale: locale), spoken: sentence(start, locale: locale))
        case (let prep?, let start?):
            PrepLine("\(prep) · \(window(start, locale: locale))",
                     spoken: "\(prep). \(sentence(start, locale: locale))")
        }
    }

    private static func window(_ start: StartCooking, locale: Locale) -> String {
        let early = start.startMinute < earlyStartMinute
        let from = start.clock(start.startMinute, locale: locale)
        if early {
            return start.isEstimate
                ? String(localized: "Cook from around \(from)", comment: "Day card prep line: an estimated morning start")
                : String(localized: "Cook from \(from)", comment: "Day card prep line: a morning start, one clock time")
        }
        let range = start.range(locale: locale)
        return start.isEstimate
            ? String(localized: "Cook around \(range)", comment: "Day card prep line: an estimated time range to cook in")
            : String(localized: "Cook \(range)", comment: "Day card prep line: the time range to cook in")
    }

    private static func sentence(_ start: StartCooking, locale: Locale) -> String {
        let from = start.clock(start.startMinute, locale: locale), dinner = start.clock(start.dinnerMinute, locale: locale)
        return start.isEstimate
            ? String(localized: "Start cooking around \(from) for dinner at \(dinner)",
                     comment: "VoiceOver, day card: an estimated start and the dinner time")
            : String(localized: "Start cooking at \(from) for dinner at \(dinner)",
                     comment: "VoiceOver, day card: the start and the dinner time")
    }
}
