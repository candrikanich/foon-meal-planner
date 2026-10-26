import Foundation
import Testing
@testable import Foon

struct SupabaseConfigTests {
    private let validInfo: [String: Any] = [
        SupabaseConfig.urlKey: "http://127.0.0.1:54421",
        SupabaseConfig.anonKeyKey: "local-anon-key",
    ]

    @Test func readsURLAndKeyFromInfoDictionary() throws {
        let config = try SupabaseConfig(info: validInfo)
        #expect(config.url == URL(string: "http://127.0.0.1:54421"))
        #expect(config.anonKey == "local-anon-key")
    }

    @Test(arguments: [SupabaseConfig.urlKey, SupabaseConfig.anonKeyKey])
    func missingValueIsReported(key: String) {
        var info = validInfo
        info.removeValue(forKey: key)
        #expect(throws: SupabaseConfig.LoadError.missing(key: key)) {
            try SupabaseConfig(info: info)
        }
    }

    // An xcconfig without a value for the variable expands to an empty string in Info.plist.
    @Test(arguments: [SupabaseConfig.urlKey, SupabaseConfig.anonKeyKey])
    func emptyValueIsReportedAsMissing(key: String) {
        var info = validInfo
        info[key] = "  "
        #expect(throws: SupabaseConfig.LoadError.missing(key: key)) {
            try SupabaseConfig(info: info)
        }
    }

    @Test(arguments: ["127.0.0.1:54421", "ftp://example.com", "https://", "not a url"])
    func urlMustBeHTTPWithHost(raw: String) {
        var info = validInfo
        info[SupabaseConfig.urlKey] = raw
        #expect(throws: SupabaseConfig.LoadError.invalidURL(raw)) {
            try SupabaseConfig(info: info)
        }
    }
}
