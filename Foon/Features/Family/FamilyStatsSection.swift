import SwiftUI

/// "This month" on the Family tab, for everyone in the family. Nothing shows until the counts load, and a failed load
/// just leaves it out.
struct FamilyStatsSection: View {
    let stats: FamilyStats?

    var body: some View {
        if let stats {
            Section {
                if stats.isEmpty {
                    Text("Once a week's plan is approved, this month's dinners show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats.lines, id: \.self) { line in
                        Label(line.title, systemImage: line.systemImage)
                    }
                }
            } header: {
                Text("This month")
            } footer: {
                if let note = stats.estimateNote {
                    Text(note)
                }
            }
        }
    }
}

#Preview("A busy month") {
    List { FamilyStatsSection(stats: .sample) }
}

#Preview("Nothing yet") {
    List { FamilyStatsSection(stats: FamilyStats()) }
}
