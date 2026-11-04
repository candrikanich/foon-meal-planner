import SwiftUI

/// "Who's pitching in" on the Family tab, for planners only (the server refuses anyone else too). Family order, one
/// warm line per person, and at most one quiet note. Nothing shows until it loads, and a failed load leaves it out.
struct EngagementSection: View {
    let rows: [Engagement.Row]?

    var body: some View {
        if let rows, !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    EngagementRow(row: row)
                }
            } header: {
                Text("Who's pitching in")
            } footer: {
                Text("Only planners see this. A word in person goes further than a reminder.")
            }
        }
    }
}

private struct EngagementRow: View {
    let row: Engagement.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemberAvatar(member: row.member, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.member.firstName).font(.body.weight(.medium))
                if let thisWeek = row.thisWeek {
                    Text(thisWeek).font(.subheadline)
                }
                if let lately = row.lately {
                    Text(lately).font(.subheadline).foregroundStyle(.secondary)
                }
                if let note = row.note {
                    Text(note).font(.subheadline).italic().foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The name, then each line as a sentence, with commas for the " · " between counts so they read as pauses.
    private var accessibilityText: String {
        ([row.member.firstName] + [row.thisWeek, row.lately, row.note].compactMap { $0 })
            .map { line in
                let spoken = line.replacingOccurrences(of: " · ", with: ", ")
                return spoken.last.map { ".?!".contains($0) } == true ? spoken : spoken + "."
            }
            .joined(separator: " ")
    }
}

#Preview("Pitching in") {
    List { EngagementSection(rows: Engagement.Row.samples) }
}

#Preview("Not loaded") {
    List { EngagementSection(rows: nil) }
}
