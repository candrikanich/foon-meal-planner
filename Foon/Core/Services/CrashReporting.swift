import Foundation
import Sentry

/// Crash and error reports to Sentry (#28), from Foon QA and family Foon only. Debug builds send nothing.
///
/// Kids use Foon, so reports carry no person: no user, no IP address, no screenshots or view hierarchy, no Session
/// Replay, and no failed-request headers. What's left is the crash or error, the device and OS, and sanitized request
/// paths (Sentry drops query strings). The foon-ios project scrubs IP addresses and known sensitive fields again on
/// arrival. docs/legal/privacy.md and the App Store label describe this.
struct CrashReporting: Equatable, Sendable {
    static let dsnKey = "SentryDSN"
    static let environmentKey = "SentryEnvironment"

    let dsn: String
    let environment: String

    /// Nil when the build has no DSN or environment (Debug), so nothing is sent.
    init?(info: [String: Any]) {
        guard let dsn = Self.value(for: Self.dsnKey, in: info),
              let environment = Self.value(for: Self.environmentKey, in: info)
        else { return nil }
        self.dsn = dsn
        self.environment = environment
    }

    /// Every QA trace, so a tester's slow screen shows up; a tenth of family Foon's, Sentry's suggested start.
    var tracesSampleRate: Double { environment == "production" ? 0.1 : 1.0 }

    /// Touches can name what was tapped, and console lines can hold anything the app printed.
    static func keepsBreadcrumb(category: String) -> Bool {
        !["touch", "console"].contains(category)
    }

    @MainActor
    static func start(bundle: Bundle = .main) {
        guard let config = CrashReporting(info: bundle.infoDictionary ?? [:]) else { return }
        SentrySDK.start { options in
            options.dsn = config.dsn
            options.environment = config.environment
            options.sendDefaultPii = false
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif
            options.enableCaptureFailedRequests = false
            options.tracesSampleRate = NSNumber(value: config.tracesSampleRate)
            // File paths can name a shared recipe, and SwiftData's queries can hold a family's values.
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.beforeBreadcrumb = { breadcrumb in
                keepsBreadcrumb(category: breadcrumb.category) ? breadcrumb : nil
            }
        }
    }

    #if DEBUG || FOON_QA
    /// Foon QA's Family screen sends one of these to prove reports arrive (docs/foon-qa.md).
    static func sendTestError(now: Date = .now) {
        let message = "Sentry test error \(Int(now.timeIntervalSince1970))"
        SentrySDK.capture(error: NSError(domain: "Foon.CrashReportingTest", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }
    #endif

    private static func value(for key: String, in info: [String: Any]) -> String? {
        guard let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
