import Foundation
import PostHog

/// Product events to PostHog (#28), from Foon QA only until privacy policy v3 (#356) names PostHog. Debug sends none.
///
/// Kids use Foon, so an event says only that something happened: no person, household, meal, name or allergy, no person
/// profile, no location, no screens or taps the SDK would collect on its own, and no notification text. The only
/// identifier is PostHog's random one per install. docs/app-store-submission.md describes this for the App Store label.
struct Analytics: Equatable, Sendable {
    static let keyKey = "PostHogKey"
    static let environmentKey = "PostHogEnvironment"
    static let host = "https://us.i.posthog.com"

    let key: String
    let environment: String

    /// Nil when the build has no key or environment (Debug, and family Foon until v3), so nothing is sent.
    init?(info: [String: Any]) {
        guard let key = Self.value(for: Self.keyKey, in: info),
              let environment = Self.value(for: Self.environmentKey, in: info)
        else { return nil }
        self.key = key
        self.environment = environment
    }

    /// Every event Foon sends: each one shows a family sharing the work of dinner.
    enum Event: Equatable, Sendable {
        case onboardingCompleted
        case weekBuilt
        case weekApproved
        case nightSwapped
        case nightClaimed
        case reactionAdded(ReactionKind)
        case memberJoined
        case storeModeOpened

        var name: String {
            switch self {
            case .onboardingCompleted: "onboarding_completed"
            case .weekBuilt: "week_built"
            case .weekApproved: "week_approved"
            case .nightSwapped: "night_swapped"
            case .nightClaimed: "night_claimed"
            case .reactionAdded: "reaction_added"
            case .memberJoined: "member_joined"
            case .storeModeOpened: "store_mode_opened"
            }
        }

        /// Only the kind of reaction, never who gave it or for which dish.
        var properties: [String: String] {
            switch self {
            case .reactionAdded(let kind): ["kind": kind.rawValue]
            default: [:]
            }
        }
    }

    /// Before setup, and in a build that doesn't report, the SDK drops the event.
    static func capture(_ event: Event) {
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    @MainActor
    static func start(bundle: Bundle = .main) {
        guard let analytics = Analytics(info: bundle.infoDictionary ?? [:]) else { return }
        PostHogSDK.shared.setup(analytics.config)
        PostHogSDK.shared.register(["environment": analytics.environment])
    }

    var config: PostHogConfig {
        let config = PostHogConfig(projectToken: key, host: Self.host)
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        // Without the server's city lookup, PostHog keeps no location, like Sentry's 0.0.0.0 (CrashReporting).
        config.disableGeoIp = true
        config.setBeforeSend { event in
            event.properties = Self.withoutLocation(event.properties)
            return event
        }
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        // Swizzling is how the SDK watches screens, taps and notifications; Foon sends only the events above.
        config.enableSwizzling = false
        #if os(iOS) || os(macOS)
        // An opened notification's title and body name the family's meals and people.
        config.capturePushNotificationOpened = false
        config.capturePushNotificationSubscriptions = false
        #endif
        #if os(iOS)
        config.sessionReplay = false
        config.surveys = false
        #endif
        config.errorTrackingConfig.autoCapture = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        return config
    }

    /// The SDK adds the device's time zone to every event, and a time zone narrows down where a family lives.
    static let locationKeys: Set = ["$timezone", "$timezone_offset"]

    static func withoutLocation(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { !locationKeys.contains($0.key) }
    }

    private static func value(for key: String, in info: [String: Any]) -> String? {
        let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }
}
