import Foundation
#if os(iOS)
import UIKit
#endif

/// Server push (#40 part 2): this device's APNs token, on the server while this person has reminders on. The server works out
/// whose it is from the session, so nothing here names a member.
enum PushRegistration {
    /// Which APNs servers the token belongs to. Debug builds are development-signed; Staging and Release go out through
    /// TestFlight and the App Store, which sign for production.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Asks the system for a token, once a launch: re-plans run often, and each answer is a call to the server. The system
    /// answers through the app delegate, with the same token or a new one.
    @MainActor
    static func ask() {
        guard !hasAsked else { return }
        hasAsked = true
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    @MainActor private static var hasAsked = false

    /// The system gave a token: on the server it goes, under whoever is signed in. Best effort: the next launch tries again.
    static func received(_ token: Data, client: NotificationClient, device: ReminderDevice = ReminderDevice()) async {
        let hex = hex(token)
        device.pushToken = hex
        try? await client.registerPush(hex, environment)
    }

    /// Reminders off, or signing out: this device stops getting this person's pushes. Kept for next time if there's no signal.
    @MainActor
    static func forget(client: NotificationClient, device: ReminderDevice = ReminderDevice()) async {
        guard let token = device.pushToken else { return }
        guard (try? await client.unregisterPush(token)) != nil else { return }
        device.pushToken = nil
        // Turned back on later, in this launch: ask again, so the token goes back on the server.
        hasAsked = false
    }
}

#if os(iOS)
/// Only for the token: notification taps and actions go through `CookAlertPresenter`.
final class FoonAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard (try? SupabaseConfig.fromMainBundle()) != nil else { return }
        Task { await PushRegistration.received(deviceToken, client: .live(SupabaseService.shared.client)) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}
}
#endif
