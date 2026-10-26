import Foundation
import Testing
@testable import Foon

/// Needs `supabase start` and `scripts/write-local-config.sh`; enable with `TEST_RUNNER_FOON_LOCAL_SUPABASE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOON_LOCAL_SUPABASE"] != nil))
struct SupabaseLocalStackTests {
    @Test func appBundleConfigReachesLocalStack() async throws {
        let config = try SupabaseConfig.fromMainBundle()
        var request = URLRequest(url: config.url.appending(path: "auth/v1/health"))
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        let (_, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func sharedServiceBuildsFromAppBundle() {
        _ = SupabaseService.shared.client
    }
}
