import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Sends what's waiting on this device: the after-dinner card's answers (taken in first), check-ins, and after-dinner answers.
/// The card can't send or wake the app itself, so this runs whenever the app does: a screen about to read the week, a
/// reminder's button, and on iPhone and iPad a background refresh.
enum WaitingAnswers {
    static func send(device: ReminderDevice, client: NotificationClient) async {
        device.takeInCardAnswers()
        await CheckInDelivery.send(device: device, client: client)
        await DinnerAnswerDelivery.send(device: device, client: client)
        #if os(iOS)
        if device.hasWaitingAnswers { AnswerRefresh.schedule() }
        #endif
    }
}

#if os(iOS)
/// A background refresh that sends what's waiting, for the card's answers above all: nothing else wakes the app for them. iOS
/// decides when, or whether, it runs.
enum AnswerRefresh {
    /// In `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let id = "com.andrikanich.foon.answers"

    /// Replaces any already asked for.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
