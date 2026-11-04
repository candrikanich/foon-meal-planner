import Foundation
import Observation

/// Dinner memories on this device (#65, part 3): off until this person turns it on. While the screen is open it
/// reads the library a few months at a time, newest first. Only the switch is kept; photo identifiers live in memory
/// until the screen closes or the switch goes off.
@Observable @MainActor
final class DinnerMemoriesStore {
    private(set) var isOn: Bool
    private(set) var access: PhotoAccess
    private(set) var dinners: [MemoryDinner] = []
    private(set) var isLoading = false
    private(set) var failed = false
    /// A page came back with no dinners logged at all, so there's nothing further back to read.
    private(set) var reachedEnd = false
    /// Pages read so far; the next one reaches three months further back.
    private(set) var pagesLoaded = 0
    /// Bumped by turning off or a change of access, so a read that was under way can't land afterwards.
    private var generation = 0

    let source: PhotoLibrarySource
    private let defaults: UserDefaults

    static let onKey = "dinnerMemories.on"

    init(source: PhotoLibrarySource, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        access = source.access()
        isOn = defaults.bool(forKey: Self.onKey)
    }

    /// On, and the library can be read: the timeline shows.
    var isShowing: Bool { isOn && access.canRead }
    var isEmpty: Bool { reachedEnd && dinners.isEmpty }
    /// Changes whenever the next page to read changes, including after a reset, so the screen knows to ask again.
    var nextRead: String { "\(generation).\(pagesLoaded)" }

    /// Asks for access if it hasn't been asked. On only if some access is granted, limited included.
    func turnOn() async {
        access = source.access()
        if access == .notAsked { access = await source.requestAccess() }
        setOn(access.canRead)
    }

    func turnOff() {
        setOn(false)
        reset()
    }

    /// Back from Settings: the person may have allowed or taken away access there.
    func checkAccess() {
        let was = access
        access = source.access()
        if access != was { reset() }
    }

    /// Reads the next few months back: logged nights from the server, then this device's photos around each dinner.
    func loadMore(logs: @Sendable (_ from: CalendarDay, _ through: CalendarDay) async throws -> [MemoryLog],
                  settings: HouseholdSettings, today: CalendarDay) async {
        access = source.access()
        guard isShowing, !isLoading, !reachedEnd else { return }
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        let page = DinnerMemories.page(pagesLoaded, today: today, calendar: settings.dayCalendar)
        do {
            let logged = try await logs(page.from, page.through)
            guard current == generation else { return }
            let nights = DinnerMemories.nights(from: logged)
            let photos = nights.isEmpty
                ? [] : await source.photos(DinnerMemories.windows(for: nights, settings: settings))
            guard current == generation, isShowing else { return }
            dinners += DinnerMemories.dinners(nights: nights, photos: photos, settings: settings)
            failed = false
            pagesLoaded += 1
            reachedEnd = logged.isEmpty
        } catch {
            // Scrolled away mid-read: not a failure. The page wasn't counted, so it's read when the bottom shows again.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            guard current == generation, !cancelled, !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Signing out turns it off: the next person on this device chooses for themselves.
    static func clearDevice(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: onKey)
    }

    private func reset() {
        generation += 1
        dinners = []
        pagesLoaded = 0
        reachedEnd = false
        failed = false
        isLoading = false
    }

    private func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Self.onKey)
    }
}
