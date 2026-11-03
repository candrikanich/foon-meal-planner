import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The after-dinner prompt's card, on a long-press (docs/spec.md → On-device reminders → After-dinner prompt). One tap answers.
/// No network and no sign-in here: the answer is saved as a file in the App Group (`DinnerCardInbox`), and the app takes it in
/// and sends it the next time it runs (opened, a reminder's button, or a background refresh).
final class DinnerViewController: UIViewController, UNNotificationContentExtension {
    private let card = DinnerCard()
    private var prompt: (id: String, payload: ReminderPayload?)?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: DinnerCardView(card: card, answer: { [weak self] in self?.answer($0) },
                                                               somethingElse: { [weak self] in self?.somethingElse() }))
        host.sizingOptions = .preferredContentSize
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = container.preferredContentSize
    }

    func didReceive(_ notification: UNNotification) {
        prompt = (notification.request.identifier, ReminderPayload(userInfo: notification.request.content.userInfo))
        // The card has every answer, so the system's list of the same buttons under it would only repeat them.
        extensionContext?.notificationActions = []
    }

    private func answer(_ choice: DinnerAnswer.Answer) {
        guard !card.saved, let prompt else { return }
        // Nothing says whose night it is, or there's no App Group to save to: the app's card can take the answer instead,
        // rather than this one losing it.
        guard let answered = DinnerPrompt.answer(choice, id: prompt.id, payload: prompt.payload, now: .now),
              let inbox = DinnerCardInbox.shared, (try? inbox.add(answered)) != nil else {
            extensionContext?.performNotificationDefaultAction()
            return
        }
        let center = UNUserNotificationCenter.current()
        // Answered, so its buttons can't write over the answer later. Now, in case the card is closed before the pause ends.
        center.removeDeliveredNotifications(withIdentifiers: [prompt.id])
        center.removePendingNotificationRequests(withIdentifiers: answered.cancels)
        card.saved = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.extensionContext?.dismissNotificationContentExtension()
        }
    }

    /// Opens the app's card, which has the swap sheet: the same as tapping the notification.
    private func somethingElse() {
        extensionContext?.performNotificationDefaultAction()
    }
}
