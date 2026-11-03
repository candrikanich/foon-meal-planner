import Foundation
import UserNotifications

/// Whether this device may show reminders.
enum ReminderPermission: Equatable, Sendable {
    /// Foon hasn't asked, or hasn't checked yet.
    case notAsked
    case on
    /// Said no, or turned them off in Settings. Only Settings can change it.
    case off
}

/// The notification center, as closures, so tests see what's handed over without touching the real one.
/// Works the same on iOS and macOS.
struct ReminderCenter: Sendable {
    var permission: @Sendable () async -> ReminderPermission
    /// Asks the system once. Returns what the person chose.
    var requestPermission: @Sendable () async -> ReminderPermission
    /// Every pending identifier, cook-mode timers' too.
    var pendingIDs: @Sendable () async -> [String]
    /// Returns whether it took. The same identifier replaces what's there.
    var add: @Sendable (_ reminder: PlannedReminder, _ after: TimeInterval) async -> Bool
    var remove: @Sendable (_ ids: [String]) -> Void
    /// Sign-out and a gone household: nothing pending, nothing left in Notification Center. Cook mode's timers go too: they
    /// can't outlive the screen that started them.
    var removeEverything: @Sendable () -> Void
    /// What's showing in Notification Center, and taking some of it away.
    var deliveredIDs: @Sendable () async -> [String] = { [] }
    var removeDelivered: @Sendable (_ ids: [String]) -> Void = { _ in }
    /// Asks for an APNs token (server push), which arrives through the app delegate.
    var askForPushToken: @Sendable @MainActor () -> Void = {}
}

extension ReminderCenter {
    static let prepCategory = "foon.reminder.prep"
    static let prepNoSnoozeCategory = "foon.reminder.prep.nosnooze"
    static let doneAction = "foon.reminder.done"
    static let snoozeAction = "foon.reminder.snooze"
    static let swapAction = "foon.reminder.swap"
    static let checkInCategory = "foon.reminder.checkin"
    static let homeAction = "foon.reminder.home"
    static let notHomeAction = "foon.reminder.nothome"
    static let afterDinnerCategory = "foon.reminder.afterdinner"
    static let wasntHomeAction = "foon.reminder.wasnthome"
    static let somethingElseAction = "foon.reminder.somethingelse"

    static func reactAction(_ kind: ReactionKind) -> String { "foon.reminder.react.\(kind.rawValue)" }

    static func reaction(fromAction action: String) -> ReactionKind? {
        ReactionKind.allCases.first { reactAction($0) == action }
    }

    /// Done and Remind me in an hour don't open the app, and Swap does.
    /// Which set of actions a reminder offers. "Remind me in an hour" only if an hour from then is before dinner, so it can't be
    /// a button that does nothing.
    static func category(for reminder: PlannedReminder) -> String? {
        if reminder.kind == .checkIn { return checkInCategory }
        if reminder.kind == .afterDinner, case .rate = reminder.route { return afterDinnerCategory }
        guard reminder.kind == .prep else { return nil }
        let inTime = reminder.dinnerAt.map { reminder.fireAt.addingTimeInterval(ReminderResponse.snoozeDelay) < $0 } ?? true
        return inTime ? prepCategory : prepNoSnoozeCategory
    }

    static func registerActions() {
        let done = UNNotificationAction(identifier: doneAction, title: String(localized: "Done", comment: "Prep reminder action"))
        let snooze = UNNotificationAction(identifier: snoozeAction,
                                          title: String(localized: "Remind me in an hour", comment: "Prep reminder action"))
        let swap = UNNotificationAction(identifier: swapAction, title: String(localized: "Swap dinner", comment: "Prep reminder action"),
                                        options: [.foreground])
        let prep = UNNotificationCategory(identifier: prepCategory, actions: [done, snooze, swap], intentIdentifiers: [])
        let noSnooze = UNNotificationCategory(identifier: prepNoSnoozeCategory, actions: [done, swap], intentIdentifiers: [])
        let home = UNNotificationAction(identifier: homeAction, title: String(localized: "Home", comment: "Check-in action"))
        let notHome = UNNotificationAction(identifier: notHomeAction, title: String(localized: "Not home", comment: "Check-in action"))
        let checkIn = UNNotificationCategory(identifier: checkInCategory, actions: [home, notHome], intentIdentifiers: [])
        // The spec's order. Each reaction and Wasn't home saves without opening the app; something else needs the swap sheet.
        let reactions = ReactionKind.allCases.map { UNNotificationAction(identifier: reactAction($0), title: $0.title) }
        let somethingElse = UNNotificationAction(identifier: somethingElseAction,
                                                 title: String(localized: "We had something else", comment: "After-dinner action"),
                                                 options: [.foreground])
        // One tap, like the check-in's Not home, but it marks them out for good, so it's shown as the drastic one.
        let wasntHome = UNNotificationAction(identifier: wasntHomeAction,
                                             title: String(localized: "Wasn't home", comment: "After-dinner action"),
                                             options: [.destructive])
        let afterDinner = UNNotificationCategory(identifier: afterDinnerCategory, actions: reactions + [somethingElse, wasntHome],
                                                 intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([prep, noSnooze, checkIn, afterDinner])
    }

    static let system = ReminderCenter(
        permission: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: .on
            case .denied: .off
            case .notDetermined: .notAsked
            @unknown default: .off
            }
        },
        requestPermission: {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .on : .off
        },
        pendingIDs: {
            await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
        },
        add: { reminder, after in
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            if let category = category(for: reminder) { content.categoryIdentifier = category }
            content.userInfo = ReminderPayload(reminder: reminder).userInfo
            // An interval, not calendar components: the time's already worked out on the household's clock, so one instant
            // is right whatever zone the phone is in, and a change of zone can't move it.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(after, 1), repeats: false)
            let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
            return (try? await UNUserNotificationCenter.current().add(request)) != nil
        },
        remove: { ids in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        },
        removeEverything: {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        },
        deliveredIDs: {
            await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
        },
        removeDelivered: { ids in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        },
        askForPushToken: { PushRegistration.ask() }
    )

    static let none = ReminderCenter(
        permission: { .notAsked }, requestPermission: { .off }, pendingIDs: { [] }, add: { _, _ in true },
        remove: { _ in }, removeEverything: {}
    )
}

extension ReminderPayload {
    init(reminder: PlannedReminder) {
        self.init(route: reminder.route, dinnerAt: reminder.dinnerAt)
    }
}
