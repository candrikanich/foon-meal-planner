import Foundation

/// The note on a list line when two things have something to say about it. Mirrors `merge_line_notes`: an allergy note can't be
/// lost to whatever the line already said, so both stay, newest first and never repeated. Past the database's limit the oldest
/// text is cut, visibly.
enum ListNotes {
    static let limit = 400

    static func merged(existing: String?, incoming: String?) -> String? {
        guard let incoming, !incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return existing }
        guard let existing else { return incoming }
        if existing.contains(incoming) { return existing }
        let joined = incoming + "; " + existing
        guard joined.unicodeScalars.count > limit else { return joined }
        var cut = String.UnicodeScalarView(joined.unicodeScalars.prefix(limit - 1))
        cut.append("…")
        return String(cut)
    }

    /// Whether a line with this note already says what `note` would add.
    static func covers(_ existing: String?, _ note: String?) -> Bool {
        guard let note else { return true }
        return existing?.contains(note) == true
    }
}
