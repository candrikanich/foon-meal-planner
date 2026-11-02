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

    @MainActor static var hasAsked = false

    /// The system gave a token: on the server it goes, under whoever is signed in. No signal: ask again on the next re-plan.
    @MainActor
    static func received(_ token: Data, client: NotificationClient, device: ReminderDevice = ReminderDevice()) async {
        let hex = hex(token)
        device.pushToken = hex
        if (try? await client.registerPush(hex, environment)) == nil { hasAsked = false }
    }

    /// Reminders off, or signing out: this device stops getting this person's pushes. Kept for next time if there's no
    /// signal, and never holds up signing out for long: the server also stops sending once that sign-in is gone.
    @MainActor
    static func forget(client: NotificationClient, device: ReminderDevice = ReminderDevice(),
                       waiting limit: Duration = .seconds(5)) async {
        // Whoever turns reminders on next, in this launch, gets the token put back on the server under them.
        hasAsked = false
        guard let token = device.pushToken else { return }
        guard await within(limit, { try await client.unregisterPush(token) }) else { return }
        device.pushToken = nil
    }

    private static func within(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await work()) != nil }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
