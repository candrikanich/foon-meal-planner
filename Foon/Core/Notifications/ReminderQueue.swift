import Foundation
import Synchronization

// Foundation only: the after-dinner card (FoonDinner) writes to these lists, and the app sends what's on them.

/// Someone's answer to a notification, kept until the app can file it. It's written by the notification delegate, which can
/// run with the app in the background and none of its screens or stores around, and by the after-dinner card.
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

/// A reaction or "Wasn't home" from the after-dinner notification, kept until the server has it, so a tap with no signal still
/// counts.
struct DinnerAnswer: Codable, Equatable, Sendable {
    enum Answer: Codable, Equatable, Sendable {
        case reaction(ReactionKind)
        case wasntHome
    }

    let nightID: UUID
    let memberID: UUID
    let answer: Answer
    let at: Date

    /// New ratings are for the last week's dinners, so one older than that can't land and isn't kept trying.
    static let keptFor: TimeInterval = 7 * 24 * 60 * 60
}

/// What's kept on this device outside the cache. Answers waiting to be sent are in `shared`, the App Group's defaults, so the
/// after-dinner card can add to them; each person's choices about reminders are in `defaults`, the app's own.
struct ReminderDevice: @unchecked Sendable {
    let defaults: UserDefaults
    let shared: UserDefaults
    private static let answersKey = "foon.reminder.answers"
    private static let checkInsKey = "foon.reminder.checkIns"
    private static let dinnerAnswersKey = "foon.reminder.dinnerAnswers"
    /// Answers can be written and read from different threads. The card is another process, but it only adds, after a tap.
    private static let answersLock = Mutex(())
    private static let moved = Mutex(false)

    /// Tests hand in their own suites. With no `shared`, the answers sit in `defaults` too.
    init(defaults: UserDefaults, shared: UserDefaults? = nil) {
        self.defaults = defaults
        self.shared = shared ?? defaults
    }

    /// This device's. Answers an older build left in the app's own defaults move to the App Group first, once a launch.
    init() {
        self.init(defaults: .standard, shared: Self.appGroupDefaults)
        let shared = self.shared
        Self.moved.withLock { moved in
            guard !moved else { return }
            Self.moveQueues(from: .standard, to: shared)
            moved = true
        }
    }

    /// The App Group on iPhone and iPad, where the card is. The Mac has no card and no App Group, so it keeps its own.
    private static var appGroupDefaults: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: AppGroup.id) ?? .standard
        #else
        .standard
        #endif
    }

    /// Moves what's waiting from `old` to `shared`, ahead of anything already there: an older build wrote it, and the card may
    /// have answered since. Running it again moves nothing.
    static func moveQueues(from old: UserDefaults, to shared: UserDefaults) {
        guard old !== shared else { return }
        answersLock.withLock { _ in
            move([ReminderAnswer].self, key: answersKey, from: old, to: shared)
            move([CheckInAnswer].self, key: checkInsKey, from: old, to: shared)
            move([DinnerAnswer].self, key: dinnerAnswersKey, from: old, to: shared)
        }
    }

    private static func move<Item: Codable>(_: [Item].Type, key: String, from old: UserDefaults, to shared: UserDefaults) {
        guard let data = old.data(forKey: key) else { return }
        let waiting = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        let there = shared.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        if !waiting.isEmpty { shared.set(try? JSONEncoder().encode(waiting + there), forKey: key) }
        old.removeObject(forKey: key)
    }

    var answers: [ReminderAnswer] {
        Self.answersLock.withLock { _ in storedAnswers }
    }

    private var storedAnswers: [ReminderAnswer] {
        shared.data(forKey: Self.answersKey).flatMap { try? JSONDecoder().decode([ReminderAnswer].self, from: $0) } ?? []
    }

    private func store(_ answers: [ReminderAnswer]) {
        shared.set(try? JSONEncoder().encode(answers), forKey: Self.answersKey)
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
        shared.data(forKey: Self.checkInsKey).flatMap { try? JSONDecoder().decode([CheckInAnswer].self, from: $0) } ?? []
    }

    func add(_ checkIn: CheckInAnswer) {
        Self.answersLock.withLock { _ in
            shared.set(try? JSONEncoder().encode(Array((storedCheckIns + [checkIn]).suffix(20))), forKey: Self.checkInsKey)
        }
    }

    /// Takes this one off, oldest first. A later answer for the same night stays, and is sent after it.
    func removeCheckIn(_ sent: CheckInAnswer) {
        Self.answersLock.withLock { _ in
            var waiting = storedCheckIns
            if let index = waiting.firstIndex(of: sent) { waiting.remove(at: index) }
            shared.set(try? JSONEncoder().encode(waiting), forKey: Self.checkInsKey)
        }
    }

    func removeCheckIns(night: UUID, member: UUID) {
        Self.answersLock.withLock { _ in
            let waiting = storedCheckIns.filter { $0.nightID != night || $0.memberID != member }
            shared.set(try? JSONEncoder().encode(waiting), forKey: Self.checkInsKey)
        }
    }

    /// Oldest first, so a change of mind lands last.
    var dinnerAnswers: [DinnerAnswer] {
        Self.answersLock.withLock { _ in storedDinnerAnswers }
    }

    private var storedDinnerAnswers: [DinnerAnswer] {
        shared.data(forKey: Self.dinnerAnswersKey).flatMap { try? JSONDecoder().decode([DinnerAnswer].self, from: $0) } ?? []
    }

    func add(_ answer: DinnerAnswer) {
        Self.answersLock.withLock { _ in
            shared.set(try? JSONEncoder().encode(Array((storedDinnerAnswers + [answer]).suffix(20))), forKey: Self.dinnerAnswersKey)
        }
    }

    func removeDinnerAnswer(_ sent: DinnerAnswer) {
        Self.answersLock.withLock { _ in
            var waiting = storedDinnerAnswers
            if let index = waiting.firstIndex(of: sent) { waiting.remove(at: index) }
            shared.set(try? JSONEncoder().encode(waiting), forKey: Self.dinnerAnswersKey)
        }
    }

    func removeDinnerAnswers(night: UUID, member: UUID) {
        Self.answersLock.withLock { _ in
            let waiting = storedDinnerAnswers.filter { $0.nightID != night || $0.memberID != member }
            shared.set(try? JSONEncoder().encode(waiting), forKey: Self.dinnerAnswersKey)
        }
    }

    /// Both lists, for the answer the card or a button gave.
    func add(_ answered: DinnerPrompt.Answered) {
        add(answered.answer)
        add(answered.dinner)
    }

    func clearQueues() {
        Self.answersLock.withLock { _ in
            shared.removeObject(forKey: Self.answersKey)
            shared.removeObject(forKey: Self.checkInsKey)
            shared.removeObject(forKey: Self.dinnerAnswersKey)
        }
    }
}

/// Answering the after-dinner prompt, from its buttons or its card: the same answer either way. Pure, so it's tested without
/// the notification center.
enum DinnerPrompt {
    struct Answered: Equatable, Sendable {
        /// "done", on the prompt's record (a follow-up's goes on what it followed).
        let answer: ReminderAnswer
        let dinner: DinnerAnswer
        /// Follow-ups that no longer apply: they've answered.
        let cancels: [String]
    }

    /// Nil unless it's a prompt that says whose night it is: one from before #122 only opens the app.
    static func answer(_ answer: DinnerAnswer.Answer, id: String, payload: ReminderPayload?, now: Date) -> Answered? {
        guard ReminderID.isReminder(id), case .rate(let night, let member) = payload?.route else { return nil }
        let base = ReminderID.base(of: id)
        return Answered(answer: ReminderAnswer(id: base, response: "done", at: now),
                        dinner: DinnerAnswer(nightID: night, memberID: member, answer: answer, at: now),
                        cancels: [ReminderID.followUp(of: base)])
    }
}
