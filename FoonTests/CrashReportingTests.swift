import Testing
@testable import Foon

struct CrashReportingTests {
    private let dsn = "https://key@o1.ingest.us.sentry.io/2"

    @Test func aBuildWithoutAnEnvironmentSendsNothing() {
        #expect(CrashReporting(info: [:]) == nil)
        #expect(CrashReporting(info: ["SentryDSN": dsn, "SentryEnvironment": ""]) == nil, "Debug")
        #expect(CrashReporting(info: ["SentryDSN": " ", "SentryEnvironment": "staging"]) == nil)
    }

    @Test func qaSamplesEveryTraceAndFamilyFoonATenth() throws {
        let qa = try #require(CrashReporting(info: ["SentryDSN": dsn, "SentryEnvironment": "staging"]))
        #expect(qa.dsn == dsn)
        #expect(qa.tracesSampleRate == 1.0)
        let family = try #require(CrashReporting(info: ["SentryDSN": dsn, "SentryEnvironment": "production"]))
        #expect(family.tracesSampleRate == 0.1)
    }

    @Test func touchesAndConsoleLinesNeverLeaveTheDevice() {
        #expect(!CrashReporting.keepsBreadcrumb(category: "touch"))
        #expect(!CrashReporting.keepsBreadcrumb(category: "console"))
        #expect(CrashReporting.keepsBreadcrumb(category: "http"))
        #expect(CrashReporting.keepsBreadcrumb(category: "ui.lifecycle"))
    }

    @Test func requestQueriesNeverLeaveTheDevice() throws {
        let data: [String: Any] = ["url": "https://x.supabase.co/rest/v1/meals", "method": "GET",
                                   "http.query": "household_id=eq.abc", "http.fragment": "top"]
        let kept = try #require(CrashReporting.withoutQueries(data))
        #expect(Set(kept.keys) == ["url", "method"])
        #expect(CrashReporting.withoutQueries(nil) == nil)
    }
}
