import Foundation
import Observation
import Supabase
import Synchronization
import UserNotifications

/// What's kept on this device outside the cache: answers waiting to be filed, and each person's choice about reminders. System
/// permission is shared with cook-mode timers, so a yes there isn't a yes to reminders: that's the opt-in, and it's per person.
/// The after-dinner card can't write here (it's another process): it leaves its answers in `cardInbox` to be taken in.
struct ReminderDevice: @unchecked Sendable {
    private let defaults: UserDefaults
    let cardInbox: DinnerCardInbox?
    private static let answersKey = "foon.reminder.answers"
    private static let checkInsKey = "foon.reminder.checkIns"
    private static let dinnerAnswersKey = "foon.reminder.dinnerAnswers"
    private static let declinedKey = "foon.reminder.declined"
    private static let optedInKey = "foon.reminder.optedIn"
    /// Answers can be written and read from different threads.
    private static let answersLock = Mutex(())

    /// Tests hand in their own defaults, and no inbox unless they say.
    init(defaults: UserDefaults, cardInbox: DinnerCardInbox? = nil) {
        self.defaults = defaults
        self.cardInbox = cardInbox
    }

    /// This device's.
    init() {
        self.init(defaults: .standard, cardInbox: .shared)
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

    /// Oldest first, so a change of mind lands last.
    var dinnerAnswers: [DinnerAnswer] {
        Self.answersLock.withLock { _ in storedDinnerAnswers }
    }

    private var storedDinnerAnswers: [DinnerAnswer] {
        defaults.data(forKey: Self.dinnerAnswersKey).flatMap { try? JSONDecoder().decode([DinnerAnswer].self, from: $0) } ?? []
    }

    private func storeDinnerAnswers(_ answers: [DinnerAnswer]) {
        defaults.set(try? JSONEncoder().encode(Array(answers.suffix(20))), forKey: Self.dinnerAnswersKey)
    }

    func add(_ answer: DinnerAnswer) {
        Self.answersLock.withLock { _ in storeDinnerAnswers(storedDinnerAnswers + [answer]) }
    }

    func removeDinnerAnswer(_ sent: DinnerAnswer) {
        Self.answersLock.withLock { _ in
            var waiting = storedDinnerAnswers
            if let index = waiting.firstIndex(of: sent) { waiting.remove(at: index) }
            storeDinnerAnswers(waiting)
        }
    }

    /// An answer saved in the app at `savedAt` stands over any for that night from then or before, the card's still in their
    /// files too: otherwise an older one would be sent after it and land last.
    func removeDinnerAnswers(night: UUID, member: UUID, savedAt: Date) {
        takeInCardAnswers()
        Self.answersLock.withLock { _ in
            storeDinnerAnswers(storedDinnerAnswers.filter { $0.nightID != night || $0.memberID != member || $0.at > savedAt })
        }
    }

    /// The card's answers join the waiting lists. For one person's night the later answer wins, as an answer on the app's card
    /// replaces one still waiting: so a card answer drops older ones for that night, and one older than what's waiting is
    /// dropped itself.
    func takeInCardAnswers() {
        guard let taken = cardInbox?.takeAll(), !taken.isEmpty else { return }
        for answered in taken {
            add(answered.answer)
            let dinner = answered.dinner
            Self.answersLock.withLock { _ in
                let waiting = storedDinnerAnswers
                let sameNight = { (other: DinnerAnswer) in other.nightID == dinner.nightID && other.memberID == dinner.memberID }
                guard !waiting.contains(where: { sameNight($0) && $0.at > dinner.at }) else { return }
                storeDinnerAnswers(waiting.filter { !sameNight($0) } + [dinner])
            }
        }
    }

    var hasWaitingAnswers: Bool { !checkIns.isEmpty || !dinnerAnswers.isEmpty }

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

    /// This device's APNs token as last sent to the server (#40 part 2). `clear` leaves it: sign-out takes it off the server
    /// first, and a token that's still filed under someone needs to be known to be taken off.
    var pushToken: String? {
        get { defaults.string(forKey: Self.pushTokenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.pushTokenKey) }
    }

    private static let pushTokenKey = "foon.push.token"
    private static let ratingCadenceKey = "foon.reminder.ratingCadence"

    /// How often this person is asked to rate dinner on this phone (RatingCadence). Each night until it changes.
    func ratingCadence(_ member: UUID) -> RatingCadence {
        storedCadences[member.uuidString] ?? RatingCadence()
    }

    func setRatingCadence(_ cadence: RatingCadence, for member: UUID) {
        var all = storedCadences
        all[member.uuidString] = cadence
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.ratingCadenceKey)
    }

    private var storedCadences: [String: RatingCadence] {
        defaults.data(forKey: Self.ratingCadenceKey).flatMap { try? JSONDecoder().decode([String: RatingCadence].self, from: $0) }
            ?? [:]
    }

    /// Signing out leaves nothing of this person's.
    func clear() {
        Self.answersLock.withLock { _ in
            defaults.removeObject(forKey: Self.answersKey)
            defaults.removeObject(forKey: Self.checkInsKey)
            defaults.removeObject(forKey: Self.dinnerAnswersKey)
        }
        // Someone else's answers from the card would be sent as the next person.
        _ = cardInbox?.takeAll()
        defaults.removeObject(forKey: Self.declinedKey)
        defaults.removeObject(forKey: Self.optedInKey)
        defaults.removeObject(forKey: Self.ratingCadenceKey)
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

/// Sends the after-dinner notification's answers that are waiting, oldest first. One the server has refused for good goes, and
/// so does one too old to land. "Not allowed" stays, as a session not back yet looks the same, but so does a rating past its
/// 24 hours, so it goes once it's too old. Order only matters for one person's night: one that can't go yet holds back the later
/// answers for that night, and no others.
enum DinnerAnswerDelivery {
    private static let finalRefusals: Set<String> = ["22023", "P0002", "FD004"]

    private struct Key: Hashable {
        let night: UUID
        let member: UUID
    }

    static func send(device: ReminderDevice, client: NotificationClient, now: Date = .now) async {
        var held: Set<Key> = []
        for answer in device.dinnerAnswers {
            let key = Key(night: answer.nightID, member: answer.memberID)
            if held.contains(key) { continue }
            if now.timeIntervalSince(answer.at) < DinnerAnswer.keptFor {
                do {
                    try await client.answerDinner(answer)
                } catch let error as PostgrestError where error.code.map(finalRefusals.contains) == true {
                    // It's had its answer.
                } catch is PostgrestError {
                    held.insert(key)
                    continue
                } catch {
                    // Not reached: the rest wouldn't be either, so don't wait on each in turn.
                    return
                }
            }
            device.removeDinnerAnswer(answer)
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
        var dinner: DinnerAnswer? = nil
    }

    /// Nil for anything that isn't a reminder: cook-mode timers only open the app, as they always did.
    static func outcome(id: String, action: String, payload: ReminderPayload?, now: Date) -> Outcome? {
        guard ReminderID.isReminder(id) else { return nil }
        let base = ReminderID.base(of: id)
        let followUp = ReminderID.followUp(of: base)
        if let kind = ReminderCenter.reaction(fromAction: action) {
            return dinnerOutcome(id: id, answer: .reaction(kind), payload: payload, now: now)
        }
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
        case ReminderCenter.wasntHomeAction:
            return dinnerOutcome(id: id, answer: .wasntHome, payload: payload, now: now)
        case ReminderCenter.somethingElseAction:
            return Outcome(answer: ReminderAnswer(id: base, response: "opened", at: now), cancels: [followUp],
                           schedulesAgain: false, route: payload?.route)
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

    /// A server push (#40 part 2) has no reminder record and no buttons yet: opening it goes where it says. Nothing for
    /// anything else, which a cook-mode timer is.
    static func pushRoute(action: String, payload: ReminderPayload?) -> ReminderRoute? {
        guard action == UNNotificationDefaultActionIdentifier else { return nil }
        return payload?.route
    }

    private static func dinnerOutcome(id: String, answer: DinnerAnswer.Answer, payload: ReminderPayload?,
                                      now: Date) -> Outcome? {
        guard let answered = DinnerPrompt.answer(answer, id: id, payload: payload, now: now) else { return nil }
        return Outcome(answer: answered.answer, cancels: answered.cancels, schedulesAgain: false, route: nil,
                       dinner: answered.dinner)
    }
}
