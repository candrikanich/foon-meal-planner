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
    /// Open offers to cook, for nights from a week ago on: dinner jobs read the whole week's.
    private(set) var claims: [NightClaim] = []
    /// Why the last offer didn't go through, and for which night.
    private(set) var claimNote: (nightID: UUID, text: String)?
    /// Bumped when the server refuses a claim: this device is behind on the night, or the away dates, so This Week reads them.
    private(set) var claimRefusals = 0
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
        claimNote = nil
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
            async let claims = client.claims(householdID, today.adding(days: -7))
            let loaded = try await (nights, logs, thanks, claims)
            guard generation == loadGeneration else { return }
            (self.nights, self.logs, self.thanks, self.claims) = loaded
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

    /// Last night's and tonight's dinners with a cook, for Thanks, chef, and for the cook to say "That wasn't me".
    func recentlyCooked(me: UUID? = nil, settings: HouseholdSettings, at date: Date? = nil) -> [DinnerLog] {
        CookCredit.recent(nights: nights, logs: logs, me: me, defaultDinnerTime: settings.dinnerTime, now: date ?? now(),
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
        let saved = await write(nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in try await client.setNotHome(nightID, memberID)
        }
        // The server takes them off as the cook, unless they've been thanked. Say so rather than leave it looking done.
        if saved, log(for: nightID)?.cookedByMemberID == memberID {
            errorMessage = String(localized: "Saved. They're still down as the cook, because someone already thanked them.")
        }
        return saved
    }

    /// "That wasn't me": takes them off as the cook, and touches nothing else on the log.
    @discardableResult
    func takeOffCook(_ log: DinnerLog) async -> Bool {
        await write(log.nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in try await client.correct(log.id, .cook(nil))
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
    func saveExtras(nightID: UUID, leftovers: Bool, cookedBy: UUID?, startedFrom: UUID? = nil) async -> Bool {
        guard let log = log(for: nightID) else { return false }
        let correction = DinnerPrompts.followUp(leftovers: leftovers, startedFrom: startedFrom, chosen: cookedBy,
                                                isDish: log.mealID != nil)
        return await write(nightID, failure: String(localized: "Couldn't save that. Check your connection and try again.")) {
            [client] in try await client.correct(log.id, correction)
        }
    }

    func clearError() {
        errorMessage = nil
        claimNote = nil
    }

    // MARK: - Claims

    /// The last refusal, wherever it was tapped: This Week shows it when no night is open.
    var claimMessage: String? { claimNote?.text }

    /// The last refusal, for this night only.
    func claimMessage(for nightID: UUID) -> String? {
        claimNote?.nightID == nightID ? claimNote?.text : nil
    }

    /// "I'll cook Thursday". Returns whether it saved. A refusal reads again, so the card shows why.
    @discardableResult
    func claim(nightID: UUID, memberID: UUID) async -> Bool {
        await claimWrite(nightID, refused: String(localized: "You can offer for yourself, or for someone without their own account.")) {
            [client] in try await client.claimNight(nightID, memberID)
        }
    }

    @discardableResult
    func release(_ claim: NightClaim) async -> Bool {
        await claimWrite(claim.nightID, refused: String(localized: "Only they or a planner can take that back.")) {
            [client] in try await client.releaseClaim(claim.id)
        }
    }

    private func claimWrite(_ nightID: UUID, refused: String, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        guard !saving.contains(nightID) else { return false }
        saving.insert(nightID)
        defer { saving.remove(nightID) }
        do {
            try await work()
            claimNote = nil
            await reload()
            if errorMessage != nil { errorMessage = nil }
            return true
        } catch {
            let code = (error as? PostgrestError)?.code
            let refusal = code == "42501" ? refused : code.flatMap(Self.claimRefusal)
            claimNote = (nightID, refusal ?? String(localized: "Couldn't save that. Check your connection and try again."))
            if refusal != nil { claimRefusals += 1 }
            await reload()
            return false
        }
    }

    /// Refusals that have nothing to do with the connection get their own words.
    private static func claimRefusal(_ code: String) -> String? {
        switch code {
        case "FD005": String(localized: "Someone else just said they'd cook that night.")
        case "FD006": String(localized: "That dinner has already happened, so its cook is set on the log.")
        case "FD007": String(localized: "The family's away that night, so nobody's cooking.")
        case "FD008": String(localized: "They eat separately, so they aren't asked to cook.")
        case "FD009": String(localized: "That night's a quick pick now, so there's nothing to cook.")
        case "FD010": String(localized: "They're down as out that night. A planner can change who's home.")
        case "P0002": String(localized: "That's changed since this phone last looked. Here's the latest.")
        default: nil
        }
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
                : code == "FD011" ? String(localized: "Someone already thanked the cook, so the cook and the dish stay as they are.")
                : code == "42501" || code == "22023" ? (refused ?? failure) : failure
            return false
        }
        await reload()
        // The write landed even if that refresh didn't; don't show a load error for it.
        if errorMessage != nil { errorMessage = nil }
        return true
    }
}
