import PostHog
import Testing
@testable import Foon

struct AnalyticsTests {
    private let key = "phc_test"

    @Test func aBuildWithoutAnEnvironmentSendsNothing() {
        #expect(Analytics(info: [:]) == nil)
        #expect(Analytics(info: ["PostHogKey": key, "PostHogEnvironment": ""]) == nil, "Debug and family Foon")
        #expect(Analytics(info: ["PostHogKey": " ", "PostHogEnvironment": "staging"]) == nil)
        #expect(Analytics(info: ["PostHogKey": key, "PostHogEnvironment": "staging"])?.environment == "staging")
    }

    @Test func eventsCarryNothingButTheReactionKind() {
        let events: [Analytics.Event] = [.onboardingCompleted, .weekBuilt, .weekApproved, .nightSwapped, .nightClaimed,
                                         .memberJoined, .storeModeOpened]
        #expect(events.allSatisfy { $0.properties.isEmpty })
        #expect(Analytics.Event.reactionAdded(.notForMe).name == "reaction_added")
        #expect(Analytics.Event.reactionAdded(.notForMe).properties == ["kind": "not_for_me"])
    }

    @Test func noPersonLocationOrAutomaticEvents() throws {
        let config = try #require(Analytics(info: ["PostHogKey": key, "PostHogEnvironment": "staging"])).config
        #expect(config.host.absoluteString == Analytics.host)
        #expect(config.personProfiles == .never)
        #expect(config.disableGeoIp)
        #expect(!config.captureApplicationLifecycleEvents)
        #expect(!config.captureScreenViews)
        #expect(!config.enableSwizzling)
        #expect(!config.capturePushNotificationOpened, "a notification's text names meals and people")
        #expect(!config.errorTrackingConfig.autoCapture, "Sentry has errors")
        #expect(!config.preloadFeatureFlags)
    }

    @Test func eventsLeaveWithOnlyListedProperties() {
        let sent = Analytics.sentProperties([
            "$timezone": "America/New_York", "$device_name": "iPhone", "$session_id": "s", "$network_wifi": true,
            "$process_person_profile": false, "$geoip_disable": true, "$os_version": "26.1", "environment": "staging",
            "kind": "good",
        ])
        #expect(Set(sent.keys) == ["$process_person_profile", "$geoip_disable", "$os_version", "environment", "kind"])
    }
}
