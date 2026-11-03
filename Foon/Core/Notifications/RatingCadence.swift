import Foundation

/// How often someone's asked to rate dinner (docs/spec.md → Keeping kids engaged): each night, until three prompts in a row go
/// unanswered, then once a week as a roundup, and after a while a gentle "want these back?" on This Week. Kept on this phone,
/// per person: it's about this phone's notifications, and a reinstall or another phone just starts at each night again.
struct RatingCadence: Codable, Equatable, Sendable {
    /// Since when it's been weekly; nil while it's each night.
    var weeklySince: Date?
    /// Whether "want these back?" has been answered for this stretch, so it's asked once.
    var offeredBack = false
    /// Prompts before this don't count toward the next downshift: they're from before they asked for them back.
    var countsFrom: Date?

    static let ignoredInARow = 3
    /// "A week or two later": long enough to have seen a roundup or two.
    static let offerBackAfter: TimeInterval = 10 * 24 * 60 * 60

    var isWeekly: Bool { weeklySince != nil }

    func shouldOfferBack(at now: Date) -> Bool {
        guard let weeklySince, !offeredBack else { return false }
        return now.timeIntervalSince(weeklySince) >= Self.offerBackAfter
    }

    /// After a look at how the latest prompts went: three in a row ignored turns it weekly. Nothing else changes it here.
    func after(_ outcomes: [PromptOutcome], now: Date) -> RatingCadence {
        guard !isWeekly else { return self }
        let counted = outcomes.filter { outcome in countsFrom.map { outcome.firedAt >= $0 } ?? true }
        guard Self.ignoredStreak(counted) >= Self.ignoredInARow else { return self }
        return RatingCadence(weeklySince: now, offeredBack: false, countsFrom: countsFrom)
    }

    /// "Yes, each night": back to each night, and what was ignored before doesn't count against them.
    func takenBack(at now: Date) -> RatingCadence {
        RatingCadence(weeklySince: nil, offeredBack: false, countsFrom: now)
    }

    /// "Keep weekly": not asked again this stretch.
    func keptWeekly() -> RatingCadence {
        var kept = self
        kept.offeredBack = true
        return kept
    }

    /// The latest prompts, newest first, that went unanswered, up to the first one that was.
    static func ignoredStreak(_ outcomes: [PromptOutcome]) -> Int {
        outcomes.sorted { $0.firedAt > $1.firedAt }.prefix { !$0.answered }.count
    }
}

/// One after-dinner prompt that went out and whose card has closed, and whether anything came of it.
struct PromptOutcome: Equatable, Sendable {
    let firedAt: Date
    let answered: Bool

    /// From what this phone knows: its own record of each prompt, and the nights it has read. A prompt counts once it went out
    /// and its card has closed (a day after it went). It was answered if it was tapped or answered from the lock screen, or the
    /// night was rated on any phone, or they said they weren't home. A night this phone hasn't read (an earlier week) goes by
    /// the tap alone, so only this week and next are looked at. One whose night was then logged with no dish (takeout instead)
    /// doesn't count either way: it was taken out of Notification Center, so there was nothing left to answer.
    static func outcomes(_ records: [ReminderRecordSummary], nights: [ReminderNight], me: UUID, now: Date) -> [PromptOutcome] {
        let byID = Dictionary(nights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            guard record.kind == .afterDinner, let sent = record.sentAt, let nightID = record.nightID,
                  let night = byID[nightID], !night.hasLog || night.loggedMealID != nil,
                  now >= sent.addingTimeInterval(24 * 60 * 60) else { return nil }
            let answered = record.respondedAt != nil || night.ratedBy.contains(me) || night.attendance[me] == false
            return PromptOutcome(firedAt: sent, answered: answered)
        }
    }
}

/// What the cadence needs from a reminder this phone scheduled.
struct ReminderRecordSummary: Equatable, Sendable {
    let kind: ReminderKind?
    let nightID: UUID?
    let sentAt: Date?
    let respondedAt: Date?
}
