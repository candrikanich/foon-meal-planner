import Foundation
import Observation
import Supabase

/// The after-dinner loop on This Week: last night's and tonight's dinners, their logs, and the one-tap reactions.
/// Loads its own nights, since last night can belong to last week.
@Observable @MainActor
final class DinnerStore {
    /// "We had something else": a dish from the library or a quick pick.
    enum Instead: Equatable, Sendable {
        case meal(UUID)
        case quickPick(QuickPick)
    }

    private(set) var nights: [WeekNight] = []
    /// Logged dinners since the start of the month (or yesterday, if earlier): the cards and the cook tally.
    private(set) var logs: [DinnerLog] = []
    private(set) var thanks: [ChefThanks] = []
    private(set) var errorMessage: String?
    /// Nights with a write in flight, so their buttons don't fire twice.
    private(set) var saving: Set<UUID> = []

    let householdID: UUID
    private let client: DinnerClient
    private let now: () -> Date
    /// Bumped per load, so an older load that finishes last can't bring back an answered card.
    private var loadGeneration = 0
    /// The household's calendar, from the last load's settings.
    private var calendar = DinnerPrompts.calendar(for: HouseholdSettings())

    init(householdID: UUID, client: DinnerClient, now: @escaping () -> Date = { .now }) {
        self.householdID = householdID
        self.client = client
        self.now = now
    }

    /// Today in the household's time zone, which is what the server goes by too.
    var today: CalendarDay { CalendarDay(now(), calendar: calendar) }

    func load(settings: HouseholdSettings) async {
        calendar = DinnerPrompts.calendar(for: settings)
        await reload()
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let today = today
        let since = min(today.adding(days: -1), CalendarDay(year: today.year, month: today.month, day: 1))
        do {
            async let nights = client.nights(householdID, today.adding(days: -1), today)
            async let logs = client.logs(householdID, since)
            async let thanks = client.thanks(householdID, since)
            let loaded = try await (nights, logs, thanks)
            guard generation == loadGeneration else { return }
            (self.nights, self.logs, self.thanks) = loaded
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !(error is CancellationError) else { return }
            errorMessage = String(localized: "Couldn't load last night's dinner. Check your connection and try again.")
        }
    }

    func prompts(me: UUID, settings: HouseholdSettings, at date: Date? = nil) -> [DinnerPrompts.Prompt] {
        DinnerPrompts.due(nights: nights, logs: logs, me: me, defaultDinnerTime: settings.dinnerTime,
                          now: date ?? now(), calendar: calendar)
    }

    func extras(me: UUID, settings: HouseholdSettings, at date: Date? = nil) -> [DinnerPrompts.Prompt] {
        DinnerPrompts.extras(nights: nights, logs: logs, me: me, defaultDinnerTime: settings.dinnerTime,
                             now: date ?? now(), calendar: calendar)
    }

    /// Who cooked this month, with their thanks.
    var cookTally: [CookCredit.Tally] {
        CookCredit.thisMonth(logs: logs, thanks: thanks, today: today)
    }

    /// Last night's and tonight's dinners with a cook, for Thanks, chef.
    func recentlyCooked(settings: HouseholdSettings, at date: Date? = nil) -> [DinnerLog] {
        CookCredit.recent(nights: nights, logs: logs, defaultDinnerTime: settings.dinnerTime, now: date ?? now(),
                          calendar: calendar)
    }

    func thanks(for logID: UUID) -> [ChefThanks] {
        thanks.filter { $0.logID == logID }
    }

    @discardableResult
    func thankTheChef(_ log: DinnerLog) async -> Bool {
        await write(log.nightID, failure: String(localized: "Couldn't send that. Check your connection and try again."),
                    refused: String(localized: "That dinner can't be thanked anymore.")) {
            [client] in try await client.thankTheChef(log.id)
        }
    }

    func log(for nightID: UUID) -> DinnerLog? {
        logs.first { $0.nightID == nightID }
    }

    /// One tap: confirms the dinner and saves this person's reaction. Returns whether it saved.
    @discardableResult
    func react(nightID: UUID, memberID: UUID, _ kind: ReactionKind) async -> Bool {
        await write(nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in _ = try await client.react(nightID, memberID, kind)
        }
    }

    @discardableResult
    func notHome(nightID: UUID, memberID: UUID) async -> Bool {
        await write(nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in try await client.setNotHome(nightID, memberID)
        }
    }

    /// "We had something else": confirms the night, then records what was actually eaten. Only before anyone has
    /// rated it (the server refuses after), so a rating never moves to a different dish.
    @discardableResult
    func hadInstead(nightID: UUID, _ instead: Instead) async -> Bool {
        let correction: DinnerCorrection = switch instead {
        case .meal(let id): .dish(mealID: id, quickPick: nil)
        case .quickPick(let pick): .dish(mealID: nil, quickPick: pick)
        }
        return await write(nightID, failure: String(localized: "Couldn't change the dinner. Check your connection and try again."),
                           refused: String(localized: "Someone already rated this dinner, so it stays as it was.")) {
            [client] in
            let logID = try await client.confirm(nightID)
            try await client.correct(logID, correction)
        }
    }

    /// Whether "We had something else" is still open: nobody has rated the night yet.
    func canChangeDish(nightID: UUID) -> Bool {
        log(for: nightID)?.reactions.isEmpty ?? true
    }

    /// The first responder's leftovers and who cooked.
    @discardableResult
    func saveExtras(nightID: UUID, leftovers: Bool, cookedBy: UUID?) async -> Bool {
        guard let log = log(for: nightID) else { return false }
        return await write(nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in try await client.correct(log.id, .extras(leftovers: leftovers, cookedByMemberID: cookedBy))
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// `refused` replaces `failure` when the server turned the change down (rather than not being reached).
    private func write(_ nightID: UUID, failure: String, refused: String? = nil,
                       _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        guard !saving.contains(nightID) else { return false }
        saving.insert(nightID)
        defer { saving.remove(nightID) }
        do {
            try await work()
            errorMessage = nil
        } catch {
            let code = (error as? PostgrestError)?.code
            errorMessage = code == "FD004" ? String(localized: "They eat separately, so they don't rate dinners.")
                : code == "42501" || code == "22023" ? (refused ?? failure) : failure
            return false
        }
        await reload()
        // The write landed even if that refresh didn't; don't show a load error for it.
        if errorMessage != nil { errorMessage = nil }
        return true
    }
}
