import Foundation

/// Where a shared item goes (docs/spec.md → Share Sheet extension). Pure.
enum ShareRouter {
    enum Route: Equatable, Sendable {
        /// A recipe page: read it into the library, or save it as an idea.
        case recipeLink(URL, title: String?)
        /// A social post: no recipe card to read, so it's saved as an idea with its title and link.
        case socialLink(URL, title: String?)
        /// "milk, eggs, bread": for the quick list.
        case shoppingList([String])
        /// A photo or PDF: read on this device, then a recipe or a list.
        case capture(SharedItem.FileType)
    }

    private static let socialDomains = ["instagram.com", "instagr.am", "tiktok.com", "facebook.com", "fb.watch", "fb.com",
                                        "fb.me", "youtube.com", "youtu.be", "pin.it", "threads.net", "threads.com",
                                        "x.com", "twitter.com"]

    static func route(_ kind: SharedItem.Kind) -> Route {
        switch kind {
        case .link(let url, let title):
            isSocial(url) ? .socialLink(url, title: title) : .recipeLink(url, title: title)
        case .text(let text):
            .shoppingList(unique(IngredientParser.parse(text).map(\.name)))
        case .file(let type):
            .capture(type)
        }
    }

    /// The domain or a subdomain of it; "notinstagram.com" doesn't count.
    private static func isSocial(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        // Pinterest has a domain per country (pinterest.co.uk).
        return socialDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
            || host.split(separator: ".").contains("pinterest")
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
