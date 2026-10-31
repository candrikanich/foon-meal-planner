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
}

extension ReminderCenter {
    static let prepCategory = "foon.reminder.prep"
    static let prepNoSnoozeCategory = "foon.reminder.prep.nosnooze"
    static let doneAction = "foon.reminder.done"
    static let snoozeAction = "foon.reminder.snooze"
    static let swapAction = "foon.reminder.swap"

    /// Done and Remind me in an hour don't open the app, and Swap does.
    /// Which set of actions a reminder offers. "Remind me in an hour" only if an hour from then is before dinner, so it can't be
    /// a button that does nothing.
    static func category(for reminder: PlannedReminder) -> String? {
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
        UNUserNotificationCenter.current().setNotificationCategories([prep, noSnooze])
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
        }
    )

    static let none = ReminderCenter(
        permission: { .notAsked }, requestPermission: { .off }, pendingIDs: { [] }, add: { _, _ in true },
        remove: { _ in }, removeEverything: {}
    )
}

/// What a notification carries so it can be answered with the app closed. Routes and times, and no more than that.
struct ReminderPayload: Equatable, Sendable {
    var route: ReminderRoute
    var dinnerAt: Date?

    init(route: ReminderRoute, dinnerAt: Date?) {
        self.route = route
        self.dinnerAt = dinnerAt
    }

    init(reminder: PlannedReminder) {
        self.init(route: reminder.route, dinnerAt: reminder.dinnerAt)
    }

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        switch route {
        case .week(let day):
            info["route"] = "week"
            info["date"] = day.isoString
        case .night(let night, let day), .swap(let night, let day):
            info["route"] = "night"
            info["night"] = night.uuidString
            info["date"] = day.isoString
        case .dinnerCard:
            info["route"] = "dinner"
        }
        if let dinnerAt { info["dinner"] = String(dinnerAt.timeIntervalSince1970) }
        return info
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo["route"] as? String else { return nil }
        let day = (userInfo["date"] as? String).flatMap { text -> CalendarDay? in
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? CalendarDay(year: parts[0], month: parts[1], day: parts[2]) : nil
        }
        switch kind {
        case "week":
            guard let day else { return nil }
            route = .week(day)
        case "night":
            guard let day, let night = (userInfo["night"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            route = .night(night, day)
        case "dinner":
            route = .dinnerCard
        default:
            return nil
        }
        dinnerAt = (userInfo["dinner"] as? String).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}
