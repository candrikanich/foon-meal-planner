import Foundation
import Testing
@testable import Foon

/// Every user-facing string goes through the String Catalog (#30), so translations can land without code
/// changes. The compiler only extracts strings that use a localization API (SwiftUI literals,
/// `String(localized:)`), so a key showing up in the catalog proves its call site is localizable.
/// CI's `scripts/sync-strings.sh --check` fails when the catalog and source drift apart either way.
struct LocalizationTests {
    /// `Fixtures/Localizable.xcstrings.json` links to the real catalog and ships in the test bundle:
    /// the sandboxed test host can't read the repo checkout directly, and a `.json` name keeps Xcode
    /// from compiling it as a second catalog.
    private final class BundleToken {}

    private static func catalogKeys() throws -> Set<String> {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Localizable.xcstrings",
                                                                  withExtension: "json"))
        struct Catalog: Decodable { let sourceLanguage: String; let strings: [String: AnyDecodable] }
        struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        #expect(catalog.sourceLanguage == "en")
        return Set(catalog.strings.keys)
    }

    @Test(arguments: [
        // SwiftUI view literals
        "Try again", "Send invite", "Parent",
        // Tab titles and day cards
        "This Week", "Library", "Tonight", "Fend for yourselves",
        // Store and redeem errors
        "Couldn't load your household. Check your connection and try again.",
        "Sign in didn't work. Check your connection and try again.",
        "That invite has expired. Ask for a new one.",
        // Family row details and the editor's title
        "Kid", "Planner", "Invite sent", "Add member", "Edit %@",
        // Interpolated (format) keys
        "%@'s request", "Away until %@", "Contains %@ (%@)",
        // Allergen names inside sentences
        "tree nuts", "sesame"
    ])
    func keyIsInTheCatalog(key: String) throws {
        #expect(try Self.catalogKeys().contains(key))
    }

    /// Long multi-line keys are checked by prefix rather than retyped in full.
    @Test(arguments: ["I'm %@'s parent or guardian", "%@, join %@ on Foon"])
    func longMessageIsInTheCatalog(prefix: String) throws {
        #expect(try Self.catalogKeys().contains { $0.hasPrefix(prefix) })
    }

    /// Strings stay readable in English with no translations yet: the key is the English text.
    @Test func englishFallsBackToTheSourceText() {
        #expect(AppTab.week.title == "This Week")
        #expect(Allergen.treeNuts.displayName == "tree nuts")
        #expect(RedeemResult.expired.message == "That invite has expired. Ask for a new one.")
    }
}
