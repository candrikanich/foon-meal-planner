import Foundation
import Observation

/// Calendar awareness on this device (#64): off until a planner turns it on in Family. While it's on, This Week
/// reads the calendar fresh on each load and suggests rushed for busy evenings. Only the switch and dismissed night
/// ids are kept.
@Observable @MainActor
final class CalendarBusyStore {
    private(set) var isOn: Bool
    private(set) var access: CalendarAccess
    private(set) var dismissed: Set<UUID>
    /// In memory only, and only times: dropped when the setting goes off or access is taken away.
    private var events: [BusyEvent] = []
    /// Bumped by each refresh and by turning off, so a slower, older read can't land over a newer answer.
    private var generation = 0

    private let source: CalendarSource
    private let defaults: UserDefaults
    private let now: () -> Date

    static let onKey = "calendarAwareness.on"
    static let dismissedKey = "calendarAwareness.dismissed"
    /// Plenty for this week and next; older ids are dropped so the list can't grow forever.
    static let keptDismissals = 40

    init(source: CalendarSource, defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }) {
        self.source = source
        self.defaults = defaults
        self.now = now
        access = source.access()
        isOn = defaults.bool(forKey: Self.onKey)
        let ids = defaults.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed = Set(ids.compactMap(UUID.init(uuidString:)))
    }

    /// Asks for access if it hasn't been asked. On only if it's granted.
    func turnOn() async {
        access = source.access()
        if access == .notAsked { access = await source.requestAccess() }
        setOn(access == .granted)
    }

    func turnOff() {
        setOn(false)
        generation += 1
        events = []
    }

    /// Back from Settings: the person may have allowed or taken away access there.
    func checkAccess() {
        access = source.access()
    }

    /// Reads just the dinner windows that could take a suggestion. Access is checked each time: it can be taken
    /// away in Settings while Foon is in the background.
    func refresh(nights: [WeekNight], settings: HouseholdSettings) async {
        generation += 1
        let current = generation
        access = source.access()
        guard isOn, access == .granted,
              let range = CalendarBusy.readRange(nights: nights, settings: settings, now: now()) else {
            events = []
            return
        }
        let read = await source.events(range)
        // Turned off, or read again, while this was reading: what came back is dropped.
        guard current == generation, isOn else { return }
        events = read
    }

    func suggestions(nights: [WeekNight], settings: HouseholdSettings) -> Set<UUID> {
        guard isOn, access == .granted else { return [] }
        return CalendarBusy.suggestions(events: events, nights: nights, settings: settings, now: now(),
                                        dismissed: dismissed)
    }

    func dismiss(_ nightID: UUID) {
        dismissed.insert(nightID)
        var ids = defaults.stringArray(forKey: Self.dismissedKey) ?? []
        ids.removeAll { $0 == nightID.uuidString }
        ids.append(nightID.uuidString)
        defaults.set(Array(ids.suffix(Self.keptDismissals)), forKey: Self.dismissedKey)
    }

    /// Signing out turns it off: the next person on this device chooses for themselves.
    static func clearDevice(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: onKey)
        defaults.removeObject(forKey: dismissedKey)
    }

    private func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Self.onKey)
    }
}
