import Foundation

/// Supabase connection settings, injected per build configuration via `Config/*.xcconfig` into Info.plist.
struct SupabaseConfig: Equatable, Sendable {
    static let urlKey = "SupabaseURL"
    static let anonKeyKey = "SupabaseAnonKey"

    enum LoadError: Error, Equatable {
        case missing(key: String)
        case invalidURL(String)
    }

    let url: URL
    let anonKey: String

    init(info: [String: Any]) throws(LoadError) {
        let rawURL = try Self.value(for: Self.urlKey, in: info)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host()?.isEmpty == false
        else { throw .invalidURL(rawURL) }

        self.url = url
        self.anonKey = try Self.value(for: Self.anonKeyKey, in: info)
    }

    static func fromMainBundle() throws(LoadError) -> SupabaseConfig {
        try SupabaseConfig(info: Bundle.main.infoDictionary ?? [:])
    }

    private static func value(for key: String, in info: [String: Any]) throws(LoadError) -> String {
        guard let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { throw .missing(key: key) }
        return value
    }
}
