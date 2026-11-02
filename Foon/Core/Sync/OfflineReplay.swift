import Foundation
import PostgREST

/// A write made while offline (or before the server confirmed it), queued and replayed in order.
/// Store mode first: check-offs, adding to a list, and tapping a staple low or out.
enum OfflineChange: Codable, Equatable, Sendable {
    case setChecked(listItemID: UUID, checked: Bool)
    /// `lineID` is the id the device gave the new line, so later changes to it reach the same row. `replacing` is a line this one
    /// takes over from ("couldn't find it"). It's part of the add so the server does both or neither (`move_to_quick_list`):
    /// when it refuses, the original line stays, with any allergy note on it.
    case addToList(householdID: UUID, itemID: UUID, list: ListKind, urgency: ListUrgency, source: ListItemSource,
                   note: String?, lineID: UUID, quantity: String? = nil, planID: UUID? = nil, replacing: UUID? = nil)
    case setStock(itemID: UUID, state: StockState?)
    /// Takes a line off its list.
    case removeFromList(listItemID: UUID)
    /// Takes a line off only if a staple put it there and it's still unbought. This phone may think a line is a staple's when the
    /// server merged it into one someone added by hand, so the server decides.
    case removeStapleLine(listItemID: UUID)
    /// Bought: a staple goes back to in stock. `ifWas` is the stock this phone saw when it was checked off, so a low or out
    /// marked on another phone since, while this one was offline in the store, stays (#201). Nil when this phone didn't know
    /// it's a staple: it's restocked if it is one by then. The server decides, so for anything else nothing happens.
    case restock(itemID: UUID, ifWas: StockState?)
    /// A check-off undone: a staple goes back to the low or out it was before, if it's still in stock. A low or out marked
    /// since stays, and the server decides whether it's a staple (#201).
    case restoreStock(itemID: UUID, to: StockState)

    /// The same change aimed at the line a server merge kept instead of the device's line.
    func repointed(_ aliases: [UUID: UUID]) -> OfflineChange {
        switch self {
        case .setChecked(let listItemID, let checked):
            aliases[listItemID].map { .setChecked(listItemID: $0, checked: checked) } ?? self
        case .removeFromList(let listItemID):
            aliases[listItemID].map { .removeFromList(listItemID: $0) } ?? self
        case .removeStapleLine(let listItemID):
            aliases[listItemID].map { .removeStapleLine(listItemID: $0) } ?? self
        case .addToList(let householdID, let itemID, let list, let urgency, let source, let note, let lineID, let quantity, let planID, let replacing):
            replacing.flatMap { aliases[$0] }.map {
                .addToList(householdID: householdID, itemID: itemID, list: list, urgency: urgency, source: source, note: note,
                           lineID: lineID, quantity: quantity, planID: planID, replacing: $0)
            } ?? self
        default:
            self
        }
    }
}

/// Replays queued changes in the order they were made. Pure, so the ordering rules are unit-tested.
enum OfflineReplay {
    /// After this many unexplained failures a change is dropped, so it can't block the queue forever.
    static let maxAttempts = 10

    enum SendResult: Equatable {
        case sent
        /// Sent, and the server merged the new line into an existing open one with this id.
        case merged(into: UUID)
        /// The network isn't there: stop, and keep this change and everything after it.
        case offline
        /// The server refused it (a rule, a conflict, bad input); retrying won't help.
        case rejected
        /// The server or session is having a moment, or something unexplained: stop and count an attempt.
        case retryLater
    }

    struct Entry: Equatable, Sendable {
        let sequence: Int
        let change: OfflineChange
        let attempts: Int
    }

    struct Report: Equatable {
        var sent: [Int] = []
        var rejected: [Int] = []
        var remaining: [Int] = []
        /// The entry that just failed without explanation, to count an attempt against.
        var failedAttempt: Int?
        /// Device line ids the server merged into existing lines.
        var aliases: [UUID: UUID] = [:]
        /// Queued changes re-pointed by a merge, to store back.
        var rewritten: [Int: OfflineChange] = [:]
    }

    static func replay(_ queue: [Entry], send: @Sendable (OfflineChange) async -> SendResult) async -> Report {
        var report = Report()
        let ordered = queue.sorted { $0.sequence < $1.sequence }
        for (index, entry) in ordered.enumerated() {
            let change = entry.change.repointed(report.aliases)
            let result = await send(change)
            switch result {
            case .sent:
                report.sent.append(entry.sequence)
            case .merged(let existing):
                report.sent.append(entry.sequence)
                if case .addToList(_, _, _, _, _, _, let lineID, _, _, _) = change, lineID != existing {
                    report.aliases[lineID] = existing
                }
            case .rejected:
                report.rejected.append(entry.sequence)
            case .retryLater where entry.attempts + 1 >= maxAttempts:
                report.rejected.append(entry.sequence)
            case .offline, .retryLater:
                // Later changes wait so they can never overtake this one.
                let waiting = ordered[index...]
                report.remaining = waiting.map(\.sequence)
                report.failedAttempt = result == .retryLater ? entry.sequence : nil
                for queued in waiting where queued.change.repointed(report.aliases) != queued.change {
                    report.rewritten[queued.sequence] = queued.change.repointed(report.aliases)
                }
                return report
            }
        }
        return report
    }

    static func classify(_ error: any Error) -> SendResult {
        if let postgrest = error as? PostgrestError { return classify(postgrestCode: postgrest.code) }
        if error is CancellationError { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .cancelled:
                return .offline
            default:
                return .retryLater
            }
        }
        return .retryLater
    }

    /// Only true refusals are dropped. PGRST0xx (database unreachable), PGRST3xx (token expired), and
    /// gateway errors with no code are the server having a moment, which happens right as signal returns.
    private static func classify(postgrestCode code: String?) -> SendResult {
        guard let code else { return .retryLater }
        if code.hasPrefix("PGRST1") || code.hasPrefix("PGRST2") { return .rejected }
        if code.hasPrefix("PGRST") { return .retryLater }
        // SQLSTATE: data exceptions (22), constraint violations (23), permission and syntax (42), raised (P0).
        if ["22", "23", "42", "P0"].contains(where: code.hasPrefix) { return .rejected }
        return .retryLater
    }
}
