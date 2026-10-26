import Foundation
import PostgREST
import Synchronization
import Testing
@testable import Foon

struct OfflineReplayTests {
    private let milk = UUID()
    private let eggs = UUID()

    private func entry(_ sequence: Int, _ change: OfflineChange, attempts: Int = 0) -> OfflineReplay.Entry {
        OfflineReplay.Entry(sequence: sequence, change: change, attempts: attempts)
    }

    @Test func sendsChangesInTheOrderTheyWereMade() async {
        let sent = Recorder()
        let queue = [
            entry(3, .setChecked(listItemID: milk, checked: false)),
            entry(1, .setChecked(listItemID: milk, checked: true)),
            entry(2, .setStock(itemID: eggs, state: .low))
        ]
        let report = await OfflineReplay.replay(queue) { change in
            await sent.append(change)
            return .sent
        }
        #expect(await sent.changes == [
            .setChecked(listItemID: milk, checked: true),
            .setStock(itemID: eggs, state: .low),
            .setChecked(listItemID: milk, checked: false)
        ])
        #expect(report.sent == [1, 2, 3])
        #expect(report.remaining.isEmpty)
    }

    @Test func stopsAtTheFirstChangeThatCantReachTheServer() async {
        let queue = [
            entry(1, .setChecked(listItemID: milk, checked: true)),
            entry(2, .setChecked(listItemID: eggs, checked: true)),
            entry(3, .setChecked(listItemID: milk, checked: false))
        ]
        let report = await OfflineReplay.replay(queue) { change in
            change == .setChecked(listItemID: eggs, checked: true) ? .offline : .sent
        }
        #expect(report.sent == [1])
        #expect(report.remaining == [2, 3], "later changes wait so they never overtake earlier ones")
    }

    @Test func dropsAChangeTheServerRejectsAndKeepsGoing() async {
        let queue = [
            entry(1, .setChecked(listItemID: milk, checked: false)),
            entry(2, .setChecked(listItemID: eggs, checked: true))
        ]
        let report = await OfflineReplay.replay(queue) { change in
            change == .setChecked(listItemID: milk, checked: false) ? .rejected : .sent
        }
        #expect(report.rejected == [1])
        #expect(report.sent == [2])
    }

    @Test func givesUpOnAChangeThatKeepsFailing() async {
        let queue = [entry(1, .setChecked(listItemID: milk, checked: true), attempts: OfflineReplay.maxAttempts - 1),
                     entry(2, .setChecked(listItemID: eggs, checked: true))]
        let report = await OfflineReplay.replay(queue) { change in
            change == .setChecked(listItemID: milk, checked: true) ? .retryLater : .sent
        }
        #expect(report.rejected == [1], "an unexplained failure can't block the queue forever")
        #expect(report.sent == [2])
    }

    @Test func anUnexplainedFailureWaitsAndCountsAnAttempt() async {
        let report = await OfflineReplay.replay([entry(1, .setChecked(listItemID: milk, checked: true))]) { _ in .retryLater }
        #expect(report.remaining == [1])
        #expect(report.failedAttempt == 1)
    }

    @Test func classifiesErrors() {
        #expect(OfflineReplay.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(OfflineReplay.classify(URLError(.timedOut)) == .offline)
        // Refusals: rules, conflicts, bad input. Retrying can't help.
        for code in ["23505", "23514", "42501", "22P02", "P0001", "PGRST116", "PGRST204"] {
            #expect(OfflineReplay.classify(PostgrestError(code: code, message: code)) == .rejected, "\(code)")
        }
        // The server or the session is having a moment (database restarting, gateway errors, expired token).
        for code in ["PGRST000", "PGRST001", "PGRST003", "PGRST301", nil] as [String?] {
            #expect(OfflineReplay.classify(PostgrestError(code: code, message: "busy")) == .retryLater, "\(code ?? "nil")")
        }
        #expect(OfflineReplay.classify(CocoaError(.fileReadUnknown)) == .retryLater)
    }

    @Test func changesSurviveEncoding() throws {
        let change = OfflineChange.addToList(householdID: UUID(), itemID: milk, list: .quick, urgency: .tonight,
                                             source: .pivot, note: "for mac and cheese", lineID: UUID())
        let decoded = try JSONDecoder().decode(OfflineChange.self, from: JSONEncoder().encode(change))
        #expect(decoded == change)
    }
}

private actor Recorder {
    private(set) var changes: [OfflineChange] = []
    func append(_ change: OfflineChange) { changes.append(change) }
}

struct OfflineReplayMergeTests {
    @Test func aServerMergeRedirectsLaterChangesToTheExistingLine() async {
        let household = UUID(), item = UUID(), temporary = UUID(), existing = UUID()
        let sent = Mutex<[OfflineChange]>([])
        let queue = [
            OfflineReplay.Entry(sequence: 1, change: .addToList(householdID: household, itemID: item, list: .quick,
                                                                 urgency: .whenever, source: .manual, note: nil,
                                                                 lineID: temporary), attempts: 0),
            OfflineReplay.Entry(sequence: 2, change: .setChecked(listItemID: temporary, checked: true), attempts: 0)
        ]
        let report = await OfflineReplay.replay(queue) { change in
            sent.withLock { $0.append(change) }
            if case .addToList = change { return .merged(into: existing) }
            return .sent
        }
        #expect(sent.withLock { $0.last } == .setChecked(listItemID: existing, checked: true))
        #expect(report.aliases == [temporary: existing])
        #expect(report.sent == [1, 2])
    }

    @Test func aMergeAlsoRewritesChangesThatStayQueued() async {
        let household = UUID(), item = UUID(), temporary = UUID(), existing = UUID()
        let queue = [
            OfflineReplay.Entry(sequence: 1, change: .addToList(householdID: household, itemID: item, list: .quick,
                                                                 urgency: .whenever, source: .manual, note: nil,
                                                                 lineID: temporary), attempts: 0),
            OfflineReplay.Entry(sequence: 2, change: .setChecked(listItemID: temporary, checked: true), attempts: 0)
        ]
        let report = await OfflineReplay.replay(queue) { change in
            if case .addToList = change { return .merged(into: existing) }
            return .offline
        }
        #expect(report.remaining == [2])
        #expect(report.rewritten == [2: .setChecked(listItemID: existing, checked: true)])
    }
}
