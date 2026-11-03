import Foundation

// Foundation only: the after-dinner card (FoonDinner) builds these answers and saves them to `DinnerCardInbox`.

/// Someone's answer to a notification, kept until the app can file it. It's written by the notification delegate, which can
/// run with the app in the background and none of its screens or stores around, and comes from the after-dinner card.
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

/// Answering the after-dinner prompt, from its buttons or its card: the same answer either way. Pure, so it's tested without
/// the notification center.
enum DinnerPrompt {
    struct Answered: Codable, Equatable, Sendable {
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

/// The card's answers waiting for the app, one JSON file each in the App Group, like the share sheet's `SharedInbox`. The card
/// only adds files and the app only takes them, so two processes never write the same list.
struct DinnerCardInbox: Sendable {
    let directory: URL

    /// Nil where there's no App Group: on the Mac (no card) and in unsigned builds. The card can't save an answer then.
    static var shared: DinnerCardInbox? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            .map { DinnerCardInbox(directory: $0.appending(path: "DinnerCardAnswers")) }
        #else
        nil
        #endif
    }

    func add(_ answered: DinnerPrompt.Answered) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(answered.dinner.at.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        try JSONEncoder().encode(answered).write(to: directory.appending(path: name), options: .atomic)
    }

    /// Everything saved, oldest first, and gone from here. One that can't be read goes too: it never will be.
    func takeAll() -> [DinnerPrompt.Answered] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let answers = files.filter { $0.pathExtension == "json" }.compactMap { file -> DinnerPrompt.Answered? in
            defer { try? FileManager.default.removeItem(at: file) }
            return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DinnerPrompt.Answered.self, from: $0) }
        }
        return answers.sorted { $0.dinner.at < $1.dinner.at }
    }
}
