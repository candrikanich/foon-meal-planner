import Foundation
import Synchronization
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Server push (#40 part 2): this device's APNs token, on the server while this person has reminders on. The server works out
/// whose it is from the session, so nothing here names a member.
enum PushRegistration {
    /// Which APNs servers the token belongs to, read from the signed profile: a build run from Xcode is development-signed
    /// whatever its configuration, while App Store and TestFlight builds carry no profile and sign for production.
    static var environment: String {
        apsEnvironment(fromProfile: embeddedProfile())
    }

    /// `profile` is the CMS-signed provisioning profile; the plist inside it holds the entitlements the build was signed with.
    /// No readable profile means an App Store or TestFlight build (a simulator can't get a token at all).
    static func apsEnvironment(fromProfile profile: Data?) -> String {
        let open = Data("<?xml".utf8), close = Data("</plist>".utf8)
        guard let profile, let start = profile.range(of: open),
              let end = profile.range(of: close, in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return "production" }
        let value = entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]
        return (value as? String) == "development" ? "sandbox" : "production"
    }

    private static func embeddedProfile() -> Data? {
        #if os(macOS)
        let url = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let url = Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
        #endif
        return try? Data(contentsOf: url)
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
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
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

    /// Doesn't wait for `work` past `limit`, even when it ignores cancellation (the SDK refreshes an expired session in a
    /// task of its own).
    private static func within(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            Task { first.give((try? await work()) != nil) }
            Task {
                try? await Task.sleep(for: limit)
                first.give(false)
            }
        }
    }
}

private final class FirstAnswer: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = Mutex(continuation) }

    func give(_ answer: Bool) {
        continuation.withLock { waiting in
            waiting?.resume(returning: answer)
            waiting = nil
        }
    }
}

/// Hands the system's token to the server under whoever is signed in.
@MainActor
private func sendPushToken(_ token: Data) {
    guard (try? SupabaseConfig.fromMainBundle()) != nil else { return }
    Task { await PushRegistration.received(token, client: .live(SupabaseService.shared.client)) }
}

#if os(iOS)
/// Only for the token: notification taps and actions go through `CookAlertPresenter`.
final class FoonAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        sendPushToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}
}
#elseif os(macOS)
/// Only for the token: notification taps and actions go through `CookAlertPresenter`.
final class FoonAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        sendPushToken(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}
}
#endif
