import Foundation

/// Which after-dinner cards someone sees on This Week (docs/spec.md → After-dinner loop). A dish they were expected home
/// for shows from about an hour after dinner until the same time the next evening, until they rate it or say they
/// weren't home. Pure, so the timing is tested.
enum DinnerPrompts {
    struct Prompt: Identifiable, Equatable, Sendable {
        let night: WeekNight
        let log: DinnerLog?
        var id: UUID { night.id }

        /// The dish, as eaten if someone corrected it, starting with a capital for the card ("Chili last night?").
        var dishName: String? {
            (log == nil ? night.mealName : log?.mealName).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
    }

    static let delay: TimeInterval = 60 * 60

    /// The server's limit on a comment. It counts Unicode code points, not what looks like one character to a person:
    /// a family emoji is several.
    static let commentLimit = 140

    /// As much of what's typed as fits, cut only between whole characters.
    static func capped(_ typed: String) -> String {
        var scalars = 0
        return String(typed.prefix { character in
            scalars += character.unicodeScalars.count
            return scalars <= commentLimit
        })
    }

    /// What's saved of a typed comment: one line, trimmed, within the limit. Nil when there's nothing to say.
    static func comment(from typed: String) -> String? {
        let line = typed.split(whereSeparator: \.isNewline).joined(separator: " ")
        let words = capped(line.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The household's calendar: its time zone, else New York like the server.
    static func calendar(for settings: HouseholdSettings) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.timeZone.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    static func due(nights: [WeekNight], logs: [DinnerLog], me: UUID, defaultDinnerTime: String, now: Date,
                    calendar: Calendar = .current) -> [Prompt] {
        let logs = Dictionary(logs.map { ($0.nightID, $0) }, uniquingKeysWith: { first, _ in first })
        return nights.sorted { $0.date < $1.date }.compactMap { night in
            let log = logs[night.id]
            // A dish to rate: the planned one, or what someone said they had instead. Quick picks aren't rated.
            guard (log?.mealID ?? (log == nil ? night.mealID : nil)) != nil,
                  night.attendance[me] == true,
                  log?.reaction(of: me) == nil,
                  isOpen(night, defaultDinnerTime: defaultDinnerTime, now: now, calendar: calendar) else { return nil }
            return Prompt(night: night, log: log)
        }
    }

    /// The first responder's follow-up (leftovers, who cooked), while the night's card would still be open.
    static func extras(nights: [WeekNight], logs: [DinnerLog], me: UUID, defaultDinnerTime: String, now: Date,
                       calendar: Calendar = .current) -> [Prompt] {
        let nights = Dictionary(nights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return logs.compactMap { log in
            guard let night = nights[log.nightID], log.verified, log.confirmedByMemberID == me,
                  // Not whether there's a cook: a claim fills that in, and the card still asks about leftovers and shows it.
                  log.leftovers == nil,
                  isOpen(night, defaultDinnerTime: defaultDinnerTime, now: now, calendar: calendar) else { return nil }
            return Prompt(night: night, log: log)
        }
    }

    /// What the follow-up card saves. The cook goes only if this person changed it: the card may have started from a cook
    /// someone has since taken off, and an untouched card mustn't put them back. A quick pick clears any cook, since nobody
    /// cooks takeout.
    static func followUp(leftovers: Bool, startedFrom: UUID?, chosen: UUID?, isDish: Bool) -> DinnerCorrection {
        if !isDish { return startedFrom == nil ? .leftovers(leftovers) : .extras(leftovers: leftovers, cookedByMemberID: nil) }
        return chosen == startedFrom ? .leftovers(leftovers) : .extras(leftovers: leftovers, cookedByMemberID: chosen)
    }

    /// Leftovers are likely when someone expected was out (the spec's pre-filled guess).
    static func expectsLeftovers(_ night: WeekNight) -> Bool {
        night.attendance.values.contains(false)
    }

    /// Someone who eats separately isn't asked: the server refuses their ratings too.
    static func rates(_ member: Member) -> Bool {
        !member.eatsSeparately
    }

    /// Who Pass the phone lists. Only for ratings: someone who eats separately can still ask for a dish.
    static func whoRates(among members: [Member]) -> [Member] {
        members.filter(rates)
    }

    /// Who can rate, or ask for a dish, on this phone: yourself and anyone with no account of their own (pass the phone).
    static func raters(home: [Member], me: UUID) -> [Member] {
        home.filter { $0.id == me || $0.userID == nil }
    }

    static func isOpen(_ night: WeekNight, defaultDinnerTime: String, now: Date, calendar: Calendar) -> Bool {
        // Until the same time the next evening: a calendar day, so a DST night still ends at dinner time.
        guard let start = promptTime(night, defaultDinnerTime: defaultDinnerTime, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return now >= start && now < end
    }

    /// An hour after the night's dinner time ("18:00" or the database's "18:00:00").
    static func promptTime(_ night: WeekNight, defaultDinnerTime: String, calendar: Calendar) -> Date? {
        moment(night.dinnerTime ?? defaultDinnerTime, on: night.date, calendar: calendar)?.addingTimeInterval(delay)
    }

    /// "18:00" or the database's "18:00:00" on that day, by that calendar's clock.
    static func moment(_ time: String, on day: CalendarDay, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day.date(in: calendar))
    }
}
