import Foundation
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

    @Test func aDishAddedCarriesOnlyHowAndWhatKindOfSite() {
        #expect(Analytics.Event.dishAdded(.quickAdd).name == "dish_added")
        #expect(Analytics.Event.dishAdded(.quickAdd).properties == ["way": "quick_add"])
        #expect(Analytics.Event.dishAdded(.starterDish).properties == ["way": "starter_dish"])
        #expect(Analytics.Event.dishAdded(.pdf).properties == ["way": "pdf"])
        #expect(Analytics.Event.dishAdded(.link(.recipeSite)).properties == ["way": "link", "site": "recipe_site"])
        #expect(Analytics.Event.dishAdded(.shareSheet(.otherSocial)).properties
            == ["way": "share_sheet", "site": "other_social"])
    }

    @Test func aLinkBecomesAKindOfSiteAndNeverLeavesItself() throws {
        func site(_ link: String, read: Bool = false) throws -> Analytics.Site {
            Analytics.Site(try #require(URL(string: link)), readRecipe: read)
        }
        #expect(try site("https://www.instagram.com/reel/abc") == .instagram)
        #expect(try site("https://vm.tiktok.com/xyz") == .tiktok)
        #expect(try site("https://pin.it/123") == .otherSocial)
        #expect(try site("https://youtu.be/abc", read: true) == .otherSocial, "social wins over a read card")
        #expect(try site("https://recipes.example/chili", read: true) == .recipeSite)
        #expect(try site("https://blog.example/about") == .other)
        let sent = Analytics.Event.dishAdded(.link(try site("https://recipes.example/chili", read: true))).properties
        #expect(!sent.values.contains { $0.contains("recipes.example") })
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
            "kind": "good", "way": "link", "site": "tiktok", "url": "https://tiktok.com/x", "name": "Chili",
        ])
        #expect(Set(sent.keys) == ["$process_person_profile", "$geoip_disable", "$os_version", "environment", "kind",
                                   "way", "site"])
    }
}
