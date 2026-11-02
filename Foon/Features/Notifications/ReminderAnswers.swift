import Foundation
import Observation
import Supabase
import Synchronization

/// Someone's answer to a notification, kept until the app can file it. It's written by the notification delegate, which can
/// run with the app in the background and none of its screens or stores around.
struct ReminderAnswer: Codable, Equatable, Sendable {
    let id: String
    /// `notification_log.response`.
    let response: String
    let at: Date
    var snoozedUntil: Date?
}

/// "Home" or "Not home" from the lock screen, kept until the server has it. Tapped with no signal it must still land, or the
/// planner goes on cooking for someone who said they're out.
struct CheckInAnswer: Codable, Equatable, Sendable {
    let nightID: UUID
    let memberID: UUID
    let home: Bool
}

/// What's kept on this device outside the cache: answers waiting to be filed, and each person's choice about reminders. System
/// permission is shared with cook-mode timers, so a yes there isn't a yes to reminders: that's the opt-in, and it's per person.
struct ReminderDevice: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let answersKey = "foon.reminder.answers"
    private static let checkInsKey = "foon.reminder.checkIns"
    private static let declinedKey = "foon.reminder.declined"
    private static let optedInKey = "foon.reminder.optedIn"
    /// Answers can be written and read from different threads.
    private static let answersLock = Mutex(())

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var answers: [ReminderAnswer] {
        Self.answersLock.withLock { _ in storedAnswers }
    }

    private var storedAnswers: [ReminderAnswer] {
        defaults.data(forKey: Self.answersKey).flatMap { try? JSONDecoder().decode([ReminderAnswer].self, from: $0) } ?? []
    }

    private func store(_ answers: [ReminderAnswer]) {
        defaults.set(try? JSONEncoder().encode(answers), forKey: Self.answersKey)
    }

    func add(_ answer: ReminderAnswer) {
        Self.answersLock.withLock { _ in store(Array((storedAnswers + [answer]).suffix(100))) }
    }

    /// Takes these off the waiting list, now they're filed. One that arrived since stays.
    func removeAnswers(_ filed: [ReminderAnswer]) {
        Self.answersLock.withLock { _ in store(storedAnswers.filter { !filed.contains($0) }) }
    }

    /// Oldest first, so a change of mind lands last.
    var checkIns: [CheckInAnswer] {
        Self.answersLock.withLock { _ in storedCheckIns }
    }

    private var storedCheckIns: [CheckInAnswer] {
        defaults.data(forKey: Self.checkInsKey).flatMap { try? JSONDecoder().decode([CheckInAnswer].self, from: $0) } ?? []
    }

    func add(_ checkIn: CheckInAnswer) {
        Self.answersLock.withLock { _ in
            defaults.set(try? JSONEncoder().encode(Array((storedCheckIns + [checkIn]).suffix(20))), forKey: Self.checkInsKey)
        }
    }

    /// Takes this one off, oldest first. A later answer for the same night stays, and is sent after it.
    func removeCheckIn(_ sent: CheckInAnswer) {
        Self.answersLock.withLock { _ in
            var waiting = storedCheckIns
            if let index = waiting.firstIndex(of: sent) { waiting.remove(at: index) }
            defaults.set(try? JSONEncoder().encode(waiting), forKey: Self.checkInsKey)
        }
    }

    func removeCheckIns(night: UUID, member: UUID) {
        Self.answersLock.withLock { _ in
            let waiting = storedCheckIns.filter { $0.nightID != night || $0.memberID != member }
            defaults.set(try? JSONEncoder().encode(waiting), forKey: Self.checkInsKey)
        }
    }

    func isOptedIn(_ member: UUID) -> Bool {
        defaults.stringArray(forKey: Self.optedInKey)?.contains(member.uuidString) ?? false
    }

    func setOptedIn(_ on: Bool, for member: UUID) {
        set(on, member: member, key: Self.optedInKey)
    }

    func hasDeclined(_ member: UUID) -> Bool {
        defaults.stringArray(forKey: Self.declinedKey)?.contains(member.uuidString) ?? false
    }

    func setDeclined(_ declined: Bool, for member: UUID) {
        set(declined, member: member, key: Self.declinedKey)
    }

    private func set(_ on: Bool, member: UUID, key: String) {
        let others = (defaults.stringArray(forKey: key) ?? []).filter { $0 != member.uuidString }
        defaults.set(on ? others + [member.uuidString] : others, forKey: key)
    }

    /// Signing out leaves nothing of this person's.
    func clear() {
        Self.answersLock.withLock { _ in
            defaults.removeObject(forKey: Self.answersKey)
            defaults.removeObject(forKey: Self.checkInsKey)
        }
        defaults.removeObject(forKey: Self.declinedKey)
        defaults.removeObject(forKey: Self.optedInKey)
    }
}

/// Sends the lock screen's answers that are waiting, oldest first. One the server has an answer to goes too: it won't change its
/// mind about yesterday's night, or a planner having them out. Anything else stays for next time, and so do the ones after it. That
/// includes "not allowed", which is also what a phone sees with its session not back yet, so it's no reason to lose an answer.
enum CheckInDelivery {
    private static let finalRefusals: Set<String> = ["22023", "FD016", "P0002"]

    static func send(device: ReminderDevice, client: NotificationClient) async {
        for answer in device.checkIns {
            do {
                try await client.answerCheckIn(answer.nightID, answer.memberID, answer.home)
            } catch let error as PostgrestError where error.code.map(finalRefusals.contains) == true {
                // It's had its answer.
            } catch {
                return
            }
            device.removeCheckIn(answer)
        }
    }
}

/// Where a tapped notification is taking the person: set by the delegate, maybe before any screen exists (a cold launch), and
/// taken by This Week once it's on screen.
@Observable @MainActor
final class ReminderRouter {
    static let shared = ReminderRouter()

    private(set) var route: ReminderRoute?

    func go(to route: ReminderRoute) {
        self.route = route
    }

    func clear() {
        route = nil
    }
}

/// What answering a notification does. Pure, so it's tested without the notification center.
enum ReminderResponse {
    static let snoozeDelay: TimeInterval = 60 * 60

    struct Outcome: Equatable, Sendable {
        let answer: ReminderAnswer
        /// Follow-ups that no longer apply: they've answered.
        let cancels: [String]
        /// Schedules this one again, as it was, at `answer.snoozedUntil`.
        let schedulesAgain: Bool
        let route: ReminderRoute?
        var checkIn: CheckInAnswer? = nil
    }

    /// Nil for anything that isn't a reminder: cook-mode timers only open the app, as they always did.
    static func outcome(id: String, action: String, payload: ReminderPayload?, now: Date) -> Outcome? {
        guard ReminderID.isReminder(id) else { return nil }
        let base = ReminderID.base(of: id)
        let followUp = ReminderID.followUp(of: base)
        switch action {
        case ReminderCenter.doneAction:
            return Outcome(answer: ReminderAnswer(id: base, response: "done", at: now), cancels: [followUp],
                           schedulesAgain: false, route: nil)
        case ReminderCenter.snoozeAction:
            let until = now.addingTimeInterval(snoozeDelay)
            // An hour from now past dinner is no use to anyone, so that's as good as dismissing it.
            let inTime = payload?.dinnerAt.map { until < $0 } ?? true
            return Outcome(answer: ReminderAnswer(id: base, response: "snoozed", at: now, snoozedUntil: inTime ? until : nil),
                           cancels: [followUp], schedulesAgain: inTime, route: nil)
        case ReminderCenter.homeAction, ReminderCenter.notHomeAction:
            guard case .checkIn(let night, let member) = payload?.route else { return nil }
            let checkIn = CheckInAnswer(nightID: night, memberID: member, home: action == ReminderCenter.homeAction)
            return Outcome(answer: ReminderAnswer(id: base, response: "done", at: now), cancels: [followUp],
                           schedulesAgain: false, route: nil, checkIn: checkIn)
        case ReminderCenter.swapAction:
            var route = payload?.route
            if case .night(let night, let day) = route { route = .swap(night, day) }
            return Outcome(answer: ReminderAnswer(id: base, response: "swap", at: now), cancels: [followUp],
                           schedulesAgain: false, route: route)
        default:
            return Outcome(answer: ReminderAnswer(id: base, response: "opened", at: now), cancels: [followUp],
                           schedulesAgain: false, route: payload?.route)
        }
    }
}
