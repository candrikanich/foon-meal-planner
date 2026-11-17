import Foundation
import PostHog

/// Configures the process-wide PostHog client from build settings embedded in the app bundle.
@MainActor
enum PostHogAnalytics {
    static let projectTokenKey = "PostHogProjectToken"
    static let hostKey = "PostHogHost"
    private static var isStarted = false

    static func start(bundle: Bundle = .main) {
        guard let projectToken = value(for: projectTokenKey, in: bundle) else {
            reportMissing(projectTokenKey)
            return
        }
        guard let host = value(for: hostKey, in: bundle) else {
            reportMissing(hostKey)
            return
        }

        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.errorTrackingConfig.autoCapture = true
        config.logs.serviceName = "foon"
        PostHogSDK.shared.setup(config)
        isStarted = true
        logInfo("posthog log capture started", attributes: ["component": "analytics"])
    }

    /// Associates the device's current anonymous activity with the authenticated account.
    static func identify(userID: UUID) {
        guard isStarted else { return }
        PostHogSDK.shared.identify(userID.uuidString)
    }

    /// Returns the device to an anonymous PostHog identity after the account changes or signs out.
    static func reset() {
        guard isStarted else { return }
        PostHogSDK.shared.reset()
    }

    /// Writes only purpose-built app lifecycle records to the PostHog log exporter.
    static func logInfo(_ message: String, attributes: [String: Any]) {
        guard isStarted else { return }
        PostHogSDK.shared.logger?.info(message, attributes: attributes)
    }

    private static func value(for key: String, in bundle: Bundle) -> String? {
        guard let value = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("$("),
              !value.hasPrefix("<")
        else { return nil }
        return value
    }

    private static func reportMissing(_ key: String) {
        #if DEBUG || FOON_QA
        preconditionFailure("\(key) variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once \(key) is configured")
        #endif
    }
}
