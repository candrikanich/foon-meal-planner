import Foundation

/// Which backend a build talks to, worded for the bottom of Family. Test builds say so; the production build (the
/// one the family beta and the App Store get) says nothing. Read from the Supabase URL, which each build
/// configuration sets.
enum BackendLabel {
    static let productionHost = "itnhdikhdsujklaimqqd.supabase.co"
    static let stagingHost = "cbftcssbnfdjjxoeflvj.supabase.co"

    static func label(for url: URL) -> String? {
        switch url.host()?.lowercased() {
        case productionHost: nil
        case stagingHost: String(localized: "Staging")
        case "127.0.0.1", "localhost": String(localized: "Local")
        default: String(localized: "Test server")
        }
    }

    static var current: String? {
        (try? SupabaseConfig.fromMainBundle()).flatMap { label(for: $0.url) }
    }
}
