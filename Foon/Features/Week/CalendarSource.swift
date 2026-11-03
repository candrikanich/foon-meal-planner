import EventKit
import Foundation

/// Whether this device lets Foon read its calendar's events.
enum CalendarAccess: Equatable, Sendable {
    /// Not asked yet, or only allowed to add events (which can't read them): asking again can still say yes.
    case notAsked
    case granted
    /// Said no, or a parent or profile restricts it. Only Settings can change it.
    case refused
}

/// The calendar, as closures, so tests stub it without touching EventKit. Works the same on iOS and macOS.
struct CalendarSource: Sendable {
    var access: @Sendable () -> CalendarAccess
    /// Asks the system once. Returns what the person chose.
    var requestAccess: @Sendable () async -> CalendarAccess
    /// Every event on this device's event calendars overlapping the range, as start, end and how busy it is.
    var events: @Sendable (_ range: DateInterval) async -> [BusyEvent]
}

extension CalendarSource {
    static let system: CalendarSource = {
        let reader = EventReader()
        return CalendarSource(
            access: { EventReader.currentAccess() },
            requestAccess: {
                await reader.requestAccess()
            },
            events: { range in await reader.events(in: range) }
        )
    }()

    static let none = CalendarSource(access: { .notAsked }, requestAccess: { .refused }, events: { _ in [] })
}

/// Holds the one event store (EventKit asks for a single long-lived instance), one read at a time.
private actor EventReader {
    private let store = EKEventStore()

    nonisolated static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined, .writeOnly: .notAsked
        case .denied, .restricted: .refused
        @unknown default: .refused
        }
    }

    /// Each event is turned into a `BusyEvent` right here and the EventKit object dropped, so a title, place or
    /// attendee never leaves this function. Nothing read is saved, synced, cached, logged or counted
    /// (CLAUDE.md rule 4): the calendar is read fresh each time This Week loads.
    func requestAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return Self.currentAccess()
    }

    func events(in range: DateInterval) -> [BusyEvent] {
        guard Self.currentAccess() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).map { event in
            let declined = event.status == .canceled
                || event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true
            return BusyEvent(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                             isFree: event.availability == .free, isDeclined: declined)
        }
    }
}
