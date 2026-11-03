import Foundation

/// One calendar event, as much of it as calendar awareness needs: when, and whether it really takes the evening.
/// No title, place, people or calendar name, so nothing personal can reach a log, the cache or sync (CLAUDE.md rule 4).
struct BusyEvent: Equatable, Sendable {
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Marked free (availability), so it doesn't take anyone's time.
    let isFree: Bool
    /// This person declined it, or it was cancelled.
    var isDeclined = false

    var counts: Bool { !isAllDay && !isFree && !isDeclined }
}

/// Calendar awareness (#64, docs/spec.md → Calendar awareness): which nights look busy around dinner, so This Week
/// can suggest marking them rushed. Only a suggestion: nothing here changes a night, and Build my week never reads it.
enum CalendarBusy {
    /// The dinner window, by default: from an hour and a half before dinner (getting home, getting started) until an
    /// hour after it. Not a setting yet.
    static let minutesBefore = 90
    static let minutesAfter = 60

    /// The night's dinner window on the household's clock, from its own dinner time or the household's.
    static func window(for night: WeekNight, settings: HouseholdSettings) -> DateInterval? {
        // The same clock as the night's day: with no time zone saved yet, that's this device's.
        let calendar = settings.dayCalendar
        guard let dinner = DinnerPrompts.moment(night.dinnerTime ?? settings.dinnerTime, on: night.date,
                                                calendar: calendar) else { return nil }
        let start = dinner.addingTimeInterval(-TimeInterval(minutesBefore * 60))
        return DateInterval(start: start, end: dinner.addingTimeInterval(TimeInterval(minutesAfter * 60)))
    }

    /// Nights to suggest rushed: normal effort, someone home, not away, the window not over yet, not dismissed on this
    /// device, and at least one event that counts overlapping the window.
    static func suggestions(events: [BusyEvent], nights: [WeekNight], settings: HouseholdSettings, now: Date,
                            dismissed: Set<UUID>) -> Set<UUID> {
        let busy = events.filter(\.counts)
        guard !busy.isEmpty else { return [] }
        let open = candidates(nights, settings: settings, now: now).filter { !dismissed.contains($0.night.id) }
        let picked = open.filter { candidate in
            busy.contains { $0.start < candidate.window.end && $0.end > candidate.window.start }
        }
        return Set(picked.map(\.night.id))
    }

    /// The stretch worth reading from the calendar: the first open window to the last. Nil when no night could take a
    /// suggestion, so the calendar isn't read at all.
    static func readRange(nights: [WeekNight], settings: HouseholdSettings, now: Date) -> DateInterval? {
        let windows = candidates(nights, settings: settings, now: now).map(\.window)
        guard let start = windows.map(\.start).min(), let end = windows.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func candidates(_ nights: [WeekNight], settings: HouseholdSettings,
                                   now: Date) -> [(night: WeekNight, window: DateInterval)] {
        let today = settings.today(now: now)
        return nights.compactMap { night in
            guard night.effort == .normal, !night.readsAway(in: settings.awayDates, today: today),
                  night.attendance.isEmpty || night.attendance.values.contains(true),
                  let window = window(for: night, settings: settings), window.end > now else { return nil }
            return (night, window)
        }
    }
}
