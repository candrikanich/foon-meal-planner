import Foundation
#if os(iOS)
import BackgroundTasks
import UserNotifications
#endif

/// Sends what's waiting on this device: the after-dinner card's answers (taken in first), check-ins, and after-dinner answers.
/// The card can't send or wake the app itself, so this runs whenever the app does: a screen about to read the week, a
/// reminder's button, and on iPhone and iPad a background refresh.
enum WaitingAnswers {
    static func send(device: ReminderDevice, client: NotificationClient) async {
        device.takeInCardAnswers()
        await CheckInDelivery.send(device: device, client: client)
        await DinnerAnswerDelivery.send(device: device, client: client)
    }
}

/// When the background refresh should next run. Soon while answers are still waiting (no signal last time); otherwise half an
/// hour after the next after-dinner prompt goes out, so its card has had time to be answered. A refresh at the moment it goes
/// would find nothing and ask for tomorrow's. Nil when there's nothing to wait for.
enum RefreshPlan {
    static let retryAfter: TimeInterval = 15 * 60
    static let afterPrompt: TimeInterval = 30 * 60

    static func next(waiting: Bool, prompts: [Date], now: Date) -> Date? {
        if waiting { return now.addingTimeInterval(retryAfter) }
        return prompts.filter { $0 > now }.min()?.addingTimeInterval(afterPrompt)
    }
}

#if os(iOS)
/// A background refresh that sends what's waiting, for the card's answers above all: nothing else wakes the app for them. iOS
/// decides when, or whether, it runs, never before the date it's given.
enum AnswerRefresh {
    /// In `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let id = "com.andrikanich.foon.answers"

    /// Replaces any already asked for.
    static func schedule(at earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    /// After a send, on going to the background, and after each refresh, so one is pending for the next prompt's card.
    static func scheduleNext(device: ReminderDevice) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let prompts = pending.filter { ReminderID.isAfterDinner($0.identifier) }
            .compactMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }
        if let next = RefreshPlan.next(waiting: device.hasWaitingAnswers, prompts: prompts, now: .now) { schedule(at: next) }
    }
}
#endif
