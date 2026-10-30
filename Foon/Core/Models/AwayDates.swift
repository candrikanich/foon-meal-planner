import Foundation

/// A stretch the whole household is away (`households.settings.away_dates`), both nights included: no dinners planned,
/// nothing built for the list, and no notifications about those nights.
struct AwayDates: Codable, Hashable, Identifiable, Sendable {
    let from: CalendarDay
    let to: CalendarDay

    var id: CalendarDay { from }

    init(from: CalendarDay, to: CalendarDay) {
        self.from = from
        self.to = to
    }

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(CalendarDay.self, forKey: .from)
        to = try container.decode(CalendarDay.self, forKey: .to)
        guard from <= to else {
            throw DecodingError.dataCorruptedError(forKey: .to, in: container, debugDescription: "Ends before it starts")
        }
    }

    func contains(_ day: CalendarDay) -> Bool {
        from <= day && day <= to
    }

    /// "Dec 20 to Dec 27", or just "Dec 20".
    var summary: String {
        let first = DayCardText.dateLabel(for: from)
        guard from != to else { return first }
        return String(localized: "\(first) to \(DayCardText.dateLabel(for: to))", comment: "Away dates: two short dates")
    }

    /// The list with a new stretch in it: stretches that overlap or run on from each other become one, ones already
    /// over are dropped, and the rest are in date order.
    static func adding(_ new: AwayDates, to existing: [AwayDates], today: CalendarDay) -> [AwayDates] {
        (existing + [new]).sorted { $0.from < $1.from }.reduce(into: [AwayDates]()) { merged, next in
            if let last = merged.last, next.from <= last.to.adding(days: 1) {
                merged[merged.count - 1] = AwayDates(from: last.from, to: max(last.to, next.to))
            } else {
                merged.append(next)
            }
        }
        .filter { $0.to >= today }
    }
}

extension HouseholdSettings {
    func isAway(on day: CalendarDay) -> Bool {
        awayDates.contains { $0.contains(day) }
    }

    /// The stretches not over yet: ended ones stay stored until the next change, but there's nothing left to show.
    func awayDates(endingOnOrAfter today: CalendarDay) -> [AwayDates] {
        awayDates.filter { $0.to >= today }
    }

    /// The stretches touching the week starting on `start`.
    func awayDates(inWeekOf start: CalendarDay) -> [AwayDates] {
        let end = start.adding(days: 6)
        return awayDates.filter { $0.from <= end && $0.to >= start }
    }

    func isAwayAllWeek(of start: CalendarDay) -> Bool {
        (0..<7).allSatisfy { isAway(on: start.adding(days: $0)) }
    }
}
