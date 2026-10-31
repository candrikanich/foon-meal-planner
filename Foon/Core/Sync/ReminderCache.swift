import Foundation
import SwiftData

// The reminders' part of the offline cache. It's in the same store as the week and lists, so sign-out's wipe and the
// other-household backstop in `SyncService` cover it too.

/// This week and next, as last read. Kept apart from `CachedPlan`, which is the current week on This Week and store mode.
@Model
final class CachedReminders {
    @Attribute(.unique) var householdID: UUID
    var payload: Data

    init(householdID: UUID, payload: Data) {
        self.householdID = householdID
        self.payload = payload
    }
}

/// One reminder this person's device has scheduled: what the planner needs to know about what's gone out, and the outbox for
/// `notification_log`. Uploads wait here until they get through, separately from `PendingChange`, because a log row must never
/// hold up a shopping list change or count as "changes waiting". Nothing in it is message text.
@Model
final class NotificationRecord {
    @Attribute(.unique) var key: String
    /// The log row's id, made here so sending it twice is one row.
    var logID: UUID
    var householdID: UUID
    var memberID: UUID
    var kindRaw: String
    var nightID: UUID?
    var fireAt: Date
    var sentAt: Date?
    var respondedAt: Date?
    var response: String?
    var snoozedUntil: Date?
    var needsUpload: Bool
    /// Bumped per change, so a change made during an upload isn't marked as sent.
    var revision: Int

    init(reminder: PlannedReminder, householdID: UUID, memberID: UUID) {
        key = reminder.id
        logID = UUID()
        self.householdID = householdID
        self.memberID = memberID
        kindRaw = reminder.kind.rawValue
        nightID = reminder.nightID
        fireAt = reminder.fireAt
        needsUpload = true
        revision = 1
    }

    func changed() {
        needsUpload = true
        revision += 1
    }

    var history: ReminderHistory {
        ReminderHistory(id: key, sentAt: sentAt, respondedAt: respondedAt, snoozedUntil: snoozedUntil)
    }

    var logEntry: NotificationLogEntry {
        NotificationLogEntry(id: logID, type: kindRaw, nightID: nightID, scheduledFor: fireAt, sentAt: sentAt,
                             respondedAt: respondedAt, response: response)
    }
}
