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
        case dishAdded(DishSource)

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
            case .dishAdded: "dish_added"
            }
        }

        /// Only the kind of reaction, never who gave it or for which dish; only how a dish came in, never the dish or
        /// its address.
        var properties: [String: String] {
            switch self {
            case .reactionAdded(let kind): ["kind": kind.rawValue]
            case .dishAdded(let source): source.properties
            default: [:]
            }
        }
    }

    /// How a dish reached the library (#175): settles whether families find recipes on social media, on recipe sites,
    /// or not online at all.
    enum DishSource: Equatable, Sendable {
        case quickAdd
        case starterDish
        /// Copy and tweak.
        case copy
        /// Made from a dinner idea's name.
        case idea
        /// Read from a link typed or pasted in Foon, or an idea's link.
        case link(Site)
        /// Shared to Foon from another app.
        case shareSheet(Site)
        case photo
        case pdf

        var properties: [String: String] {
            switch self {
            case .quickAdd: ["way": "quick_add"]
            case .starterDish: ["way": "starter_dish"]
            case .copy: ["way": "copy"]
            case .idea: ["way": "idea"]
            case .link(let site): ["way": "link", "site": site.rawValue]
            case .shareSheet(let site): ["way": "share_sheet", "site": site.rawValue]
            case .photo: ["way": "photo"]
            case .pdf: ["way": "pdf"]
            }
        }
    }

    /// The kind of place a link went, never the link.
    enum Site: String, Equatable, Sendable {
        case recipeSite = "recipe_site"
        case instagram
        case tiktok
        case otherSocial = "other_social"
        case other

        /// A page Foon read a recipe card from is a recipe site; any other page that isn't social is other.
        init(_ url: URL, readRecipe: Bool) {
            switch ShareRouter.socialSite(url) {
            case "Instagram": self = .instagram
            case "TikTok": self = .tiktok
            case .some: self = .otherSocial
            case nil: self = readRecipe ? .recipeSite : .other
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
            event.properties = Self.sentProperties(event.properties)
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

    /// The only properties an event leaves with. The SDK adds more to every event, such as the device's time zone,
    /// which narrows down where a family lives; a list of what may go also stops whatever a later SDK version adds.
    static let sentKeys: Set = [
        "environment", "kind", "way", "site",
        // PostHog's own switches: without them it would build a person profile and look up a city.
        "$process_person_profile", "$geoip_disable",
        "$lib", "$lib_version", "$app_version", "$app_build", "$os_name", "$os_version",
        "$device_type", "$device_model", "$locale",
    ]

    static func sentProperties(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { sentKeys.contains($0.key) }
    }

    private static func value(for key: String, in info: [String: Any]) -> String? {
        let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }
}
