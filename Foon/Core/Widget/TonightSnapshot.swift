import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// Shared with the Tonight widget (FoonWidget), which reads it with no network or database of its own.

/// What the Tonight widget shows: the nights this phone last saw, as This Week shows them. The app writes it whenever the
/// week it holds changes; the widget only reads it. No allergies and no people, so nothing on it says who's home.
struct TonightSnapshot: Codable, Equatable, Sendable {
    struct Night: Codable, Equatable, Sendable {
        let date: CalendarDay
        /// The dish, or the quick pick in words. Nil when nothing's planned.
        let title: String?
        /// Whether `title` is something the family typed (a dish), which the lock screen hides while the phone is locked.
        let isDish: Bool
        /// "18:30", on the household's clock.
        let dinnerTime: String?
        /// The household's away dates cover it: nothing to plan.
        let isAway: Bool

        init(date: CalendarDay, title: String? = nil, isDish: Bool = false, dinnerTime: String? = nil,
             isAway: Bool = false) {
            self.date = date
            self.title = title
            self.isDish = isDish
            self.dinnerTime = dinnerTime
            self.isAway = isAway
        }
    }

    let householdID: UUID
    /// The household's time zone, so "tonight" turns over at its midnight, not the phone's.
    let timeZone: String
    var nights: [Night]

    /// The widget's kind, for reloading its timeline when the snapshot changes.
    static let widgetKind = "com.andrikanich.foon.tonight"

    /// Two weeks from yesterday: This Week and next, with room for the week to turn over before the app opens again.
    static let keptDays = 14

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar
    }

    /// The week just seen replaces its own dates. Another household's nights, and old ones, don't stay.
    func merging(_ incoming: [Night], householdID: UUID, timeZone: String, today: CalendarDay) -> TonightSnapshot {
        let kept = householdID == self.householdID ? nights : []
        let dates = Set(incoming.map(\.date))
        let fresh = TonightSnapshot(householdID: householdID, timeZone: timeZone, nights: [])
        let first = today.adding(days: -1, calendar: fresh.calendar)
        let last = today.adding(days: Self.keptDays - 1, calendar: fresh.calendar)
        let combined: [Night] = kept.filter { !dates.contains($0.date) } + incoming
        let merged = combined.filter { $0.date >= first && $0.date <= last }.sorted { $0.date < $1.date }
        return TonightSnapshot(householdID: householdID, timeZone: timeZone, nights: merged)
    }

    func night(on day: CalendarDay) -> Night? {
        nights.first { $0.date == day }
    }

    /// When the widget changes on its own: now, then each midnight on the household's clock through the last night it has.
    func refreshDates(from now: Date) -> [Date] {
        let calendar = calendar
        let today = CalendarDay(now, calendar: calendar)
        guard let last = nights.last?.date, last > today else { return [now] }
        var dates = [now]
        var day = today.adding(days: 1, calendar: calendar)
        while day <= last.adding(days: 1, calendar: calendar) {
            dates.append(day.date(in: calendar))
            day = day.adding(days: 1, calendar: calendar)
        }
        return dates
    }
}

/// The snapshot's file in the App Group. One writer (the app) and one reader (the widget), so a whole-file atomic write is
/// enough.
struct TonightFile: Sendable {
    let url: URL

    /// Nil where there's no App Group: on the Mac (no widget yet) and in unsigned builds.
    static var shared: TonightFile? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            .map { TonightFile(url: $0.appending(path: "Tonight.json")) }
        #else
        nil
        #endif
    }

    func load() -> TonightSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TonightSnapshot.self, from: data)
    }

    func save(_ snapshot: TonightSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    /// On sign-out, so the next person on this phone never sees this family's dinners.
    func clear() {
        try? FileManager.default.removeItem(at: url)
        #if canImport(WidgetKit)
        // Or the widget keeps the dinners already on its timeline until its next midnight.
        WidgetCenter.shared.reloadTimelines(ofKind: TonightSnapshot.widgetKind)
        #endif
    }
}
