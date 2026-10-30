import Foundation

/// What the Share Sheet extension hands to the app (docs/spec.md → Share Sheet extension). Compiled into both targets:
/// the extension saves it and closes, and the app does the work, signed in and online. Foundation only, so the
/// extension stays small.
struct SharedItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case link(URL, title: String?)
        case text(String)
    }

    static let textLimit = 5000
    /// The server's limits for an idea's title and link.
    static let titleLimit = 80
    static let linkLimit = 2048

    var id = UUID()
    var createdAt = Date.now
    let kind: Kind
}

extension SharedItem.Kind {
    /// Web links only: anything else (a file, another app's scheme) isn't ours to open.
    init?(url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil,
              url.absoluteString.count <= SharedItem.linkLimit else { return nil }
        var title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Some apps send the address as the title too.
        if title.hasPrefix("http://") || title.hasPrefix("https://") { title = "" }
        let clamped = String(String.UnicodeScalarView(title.unicodeScalars.prefix(SharedItem.titleLimit)))
        self = .link(url, title: clamped.isEmpty ? nil : clamped)
    }

    /// Shared text. One web link means a link, titled by whatever's around it (apps often share "Great chili
    /// https://..." as one piece of text). Anything else is words, except a lone address Foon can't use.
    init?(sharedText: String) {
        let text = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A lone address is a link or nothing; the detector below may cut a very long one short.
        if !text.contains(where: \.isWhitespace), text.contains("://") {
            guard let url = URL(string: text), let link = Self(url: url, title: nil) else { return nil }
            self = link
            return
        }
        let links = Self.webLinks(in: text)
        if links.count == 1, let (url, range) = links.first {
            var rest = text
            rest.removeSubrange(range)
            let title = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            if let link = Self(url: url, title: title) {
                self = link
                return
            }
        }
        self = .text(String(text.prefix(SharedItem.textLimit)))
    }

    /// Addresses written out with http(s), so "eggs.com" on a shopping list stays an item.
    private static func webLinks(in text: String) -> [(URL, Range<String.Index>)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text),
                  text[range].lowercased().hasPrefix("http") else { return nil }
            return (url, range)
        }
    }
}

/// Shared items waiting for the app, one JSON file each, in a folder both targets can reach (the App Group).
struct SharedInbox: Sendable {
    struct Full: Error {}

    /// Plenty for shares between app opens; a share that can't fit says so instead of filling the disk.
    static let limit = 50
    static let appGroup = "group.com.andrikanich.foon"

    let directory: URL

    /// Nil where there's no App Group: on the Mac (no share extension) and in unsigned test builds.
    static var shared: SharedInbox? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { SharedInbox(directory: $0.appending(path: "SharedInbox")) }
        #else
        nil
        #endif
    }

    func add(_ item: SharedItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard files().count < Self.limit else { throw Full() }
        try JSONEncoder().encode(item).write(to: file(item.id), options: .atomic)
    }

    /// Oldest first. A file that isn't an item is removed, so it can't block the rest.
    func pending() -> [SharedItem] {
        files().compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let item = try? JSONDecoder().decode(SharedItem.self, from: data) { return item }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Someone signed in. Items from before they signed in are theirs (they shared them, then opened Foon); items from
    /// another account on this device never reach them.
    func claim(for userID: UUID) {
        let owner = directory.appending(path: "owner")
        if let previous = try? String(contentsOf: owner, encoding: .utf8), previous != userID.uuidString { clear() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(userID.uuidString.utf8).write(to: owner, options: .atomic)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }
}
