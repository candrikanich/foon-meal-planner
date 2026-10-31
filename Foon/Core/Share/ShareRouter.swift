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

    private static let socialSites = ["instagram.com": "Instagram", "instagr.am": "Instagram", "tiktok.com": "TikTok",
                                      "facebook.com": "Facebook", "fb.watch": "Facebook", "fb.com": "Facebook",
                                      "fb.me": "Facebook", "youtube.com": "YouTube", "youtu.be": "YouTube",
                                      "pin.it": "Pinterest", "threads.net": "Threads", "threads.com": "Threads",
                                      "x.com": "X", "twitter.com": "X"]
    /// Pinterest has a domain per country. One missing here is only treated as an ordinary link, showing its address.
    private static let pinterestDomains = ["pinterest.com", "pinterest.co.uk", "pinterest.ca", "pinterest.com.au", "pinterest.de",
                                           "pinterest.fr", "pinterest.es", "pinterest.it", "pinterest.pt", "pinterest.ie",
                                           "pinterest.nz", "pinterest.at", "pinterest.ch", "pinterest.se", "pinterest.dk",
                                           "pinterest.jp", "pinterest.co.kr", "pinterest.com.mx", "pinterest.cl", "pinterest.ph"]

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

    static func isSocial(_ url: URL) -> Bool { socialSite(url) != nil }

    /// What to call an idea saved from the share screen: the name on the screen once a recipe's been read, since that's the
    /// one someone checked and it's the only one showing.
    static func ideaTitle(typed: String, read: MealDraft?) -> String { read?.name ?? typed }

    /// What to call a link with no title: "Instagram post", or the site's address without its "www."
    static func siteLabel(_ url: URL) -> String {
        if let site = socialSite(url) { return String(localized: "\(site) post", comment: "A shared link with no title") }
        return siteAddress(url)
    }

    /// For a link someone can tap: what it is, and always where it really goes.
    static func linkLabel(_ url: URL) -> String {
        let (label, address) = (siteLabel(url), siteAddress(url))
        return label == address ? address : "\(label) · \(address)"
    }

    private static func siteAddress(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The page's title, if it says what this post is. Social sites often answer an app with just their own name or a
    /// sign-in page, Instagram puts the caption inside `Name on Instagram: "the caption"`, and Facebook puts its counts
    /// and name around the title.
    static func postTitle(_ pageTitle: String?, for url: URL) -> String? {
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        guard let site = socialSite(url) else { return title }
        if let caption = title.wholeMatch(of: /(?is).+? on instagram: ["“](.*)/)?.1 {
            var words = String(caption)
            if let last = words.last, "\"”".contains(last) { words.removeLast() }
            return words.isEmpty ? nil : fitted(words)
        }
        let (lower, name) = (title.lowercased(), site.lowercased())
        // `Best chili on YouTube` is a real title; `Jack (@jack) on X` and `Cook on Instagram` only name someone.
        let namesSomeone = lower.hasSuffix(" on \(name)") && (site == "Instagram" || lower.contains("(@"))
        guard lower != name, !lower.hasPrefix("\(name) - "), !namesSomeone, !lower.contains(/\blog ?in/) else { return nil }
        let words = site == "Facebook" ? withoutFacebookFrame(title) : title
        return words.isEmpty ? nil : fitted(words)
    }

    /// `2.8M views · 1.3K reactions | The title | Facebook`
    private static func withoutFacebookFrame(_ title: String) -> String {
        title.components(separatedBy: " | ")
            .filter { $0.lowercased() != "facebook" && $0.prefixMatch(of: /(?i)[\d.,km]+ (views?|reactions?|likes?|comments?)\b/) == nil }
            .joined(separator: " | ")
    }

    /// An idea's limit, ending on a whole word.
    private static func fitted(_ title: String) -> String {
        let cut = RecipeImport.clamped(title, to: SharedItem.titleLimit)
        guard cut.count < title.count, let space = cut.lastIndex(of: " ") else { return cut }
        return String(cut[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
    }

    /// The domain or a subdomain of it; "notinstagram.com" doesn't count.
    private static func socialSite(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        if pinterestDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return "Pinterest" }
        return socialSites.first { host == $0.key || host.hasSuffix(".\($0.key)") }?.value
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
