import Foundation
import Observation
import UserNotifications

/// Cook mode's running timers. Each one also schedules a local notification for when it's done, so it goes off with
/// the app in the background or the screen locked (docs/spec.md → Notifications → Delivery: on the device). In the
/// foreground the app's notification delegate (`CookAlertPresenter`) still shows the banner and plays the sound.
@Observable @MainActor
final class CookTimers {
    struct Running: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
        let endsAt: Date

        func remaining(at now: Date) -> Int { max(Int(endsAt.timeIntervalSince(now).rounded(.up)), 0) }
    }

    /// Schedules (or cancels) the "done" alert. A closure, so tests run without the notification center.
    struct Notifier: Sendable {
        /// Returns whether alerts are allowed (false: the person turned notifications off).
        var schedule: @Sendable (_ id: UUID, _ title: String, _ body: String, _ after: TimeInterval) async -> Bool
        var cancel: @Sendable (_ id: UUID) -> Void

        static let system = Notifier(
            schedule: { id, title, body, after in
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(after, 1), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
                return true
            },
            cancel: { id in
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
            }
        )

        static let none = Notifier(schedule: { _, _, _, _ in true }, cancel: { _ in })
    }

    private(set) var running: [Running] = []
    /// Notifications are off, so a timer only shows on screen: cook mode says to keep Foon open.
    private(set) var alertsOff = false
    /// Alerts still being scheduled. Stopping waits for one to finish before cancelling it, or it would fire anyway.
    private var scheduling: [UUID: Task<Void, Never>] = [:]
    private let notifier: Notifier
    private let now: () -> Date

    init(notifier: Notifier = .system, now: @escaping () -> Date = { .now }) {
        self.notifier = notifier
        self.now = now
    }

    func start(_ timer: CookSteps.Timer, dish: String) {
        let running = Running(id: UUID(), label: timer.label, endsAt: now().addingTimeInterval(TimeInterval(timer.seconds)))
        self.running.append(running)
        let title = String(localized: "Timer done: \(timer.label)", comment: "Cook mode timer alert title")
        let body = String(localized: "Time to check on \(dish).", comment: "Cook mode timer alert body: the dish's name")
        scheduling[running.id] = Task { [notifier] in
            let allowed = await notifier.schedule(running.id, title, body, TimeInterval(timer.seconds))
            if !allowed { self.alertsOff = true }
            self.scheduling[running.id] = nil
        }
    }

    func stop(_ id: UUID) {
        running.removeAll { $0.id == id }
        cancelAlert(id)
    }

    /// Leaving cook mode stops everything, alerts included.
    func stopAll() {
        for timer in running { cancelAlert(timer.id) }
        running = []
    }

    /// Waits for alerts still being scheduled (tests, and nothing else, need to know when that's done).
    func settle() async {
        for task in Array(scheduling.values) { await task.value }
    }

    private func cancelAlert(_ id: UUID) {
        notifier.cancel(id)
        guard let pending = scheduling[id] else { return }
        Task { [notifier] in
            await pending.value
            notifier.cancel(id)
        }
    }
}

/// Shows a cook-mode alert or a reminder even while Foon is in front (otherwise a timer that ends with cook mode on screen is
/// silent), and takes answers to reminders. Set as the notification center's delegate when the app starts.
///
/// These are the completion-handler forms on purpose. The async forms finish on a background thread, which is reported to crash
/// with "Call must be made on main thread", and tapping a notification crashed on a device while this used them. Swift 6 won't
/// let the async forms be main-actor isolated, because the notification types aren't Sendable.
final class CookAlertPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = CookAlertPresenter()

    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .sound, .list]

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.foregroundOptions)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let (id, action) = (request.identifier, response.actionIdentifier)
        let (title, body) = (request.content.title, request.content.body)
        let payload = ReminderPayload(userInfo: request.content.userInfo)
        nonisolated(unsafe) let finished = completionHandler
        Task { @MainActor in
            await Self.answer(id: id, action: action, payload: payload, title: title, body: body)
            finished()
        }
    }

    /// Can run with the app in the background and none of its screens up. So it does what can't wait (cancels a follow-up,
    /// schedules a snooze), saves the answer for `ReminderStore`, and leaves the rest for the next re-plan.
    @MainActor
    private static func answer(id: String, action: String, payload: ReminderPayload?, title: String, body: String) async {
        guard let outcome = ReminderResponse.outcome(id: id, action: action, payload: payload, now: .now) else { return }
        ReminderCenter.system.remove(outcome.cancels)
        if outcome.schedulesAgain, let until = outcome.answer.snoozedUntil, let payload {
            // Only prep reminders have the action.
            _ = await ReminderCenter.system.add(
                PlannedReminder(id: outcome.answer.id, kind: .prep, nightID: nil, fireAt: until, dinnerAt: payload.dinnerAt,
                                title: title, body: body, route: payload.route),
                until.timeIntervalSinceNow
            )
        }
        ReminderDevice().add(outcome.answer)
        if let route = outcome.route { ReminderRouter.shared.go(to: route) }
    }
}
