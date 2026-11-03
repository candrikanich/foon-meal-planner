import SwiftUI

/// What the receipt says was bought, to check before anything changes: each line's item can be changed or skipped, and
/// lines Foon couldn't place wait under "Didn't recognize" until someone picks an item.
struct ReceiptReviewView: View {
    @Binding var review: ReceiptReview
    let items: [ReceiptItem]
    /// Makes a new item for a line. Nil when it worked, or what to say.
    var addNew: (_ rowID: Int, _ name: String) async -> String? = { _, _ in nil }
    @State private var picking: ReceiptReview.Row?

    private var names: [UUID: String] {
        Dictionary(items.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        List {
            Section {
                ForEach(review.matched) { row in line(row) }
            } header: {
                Text("Bought")
            } footer: {
                Text("Tap a line to change its item, or switch it off to skip it.")
            }
            if !review.unrecognized.isEmpty {
                Section {
                    ForEach(review.unrecognized) { row in line(row) }
                } header: {
                    Text("Didn't recognize")
                } footer: {
                    Text("Skipped unless you pick an item. Foon remembers what you pick, for everyone's next receipt.")
                }
            }
        }
        .sheet(item: $picking) { row in
            ReceiptItemPicker(line: row.text, items: items) { itemID in
                review.assign(row.id, to: itemID)
            } addNew: { name in
                await addNew(row.id, name)
            }
        }
    }

    private func line(_ row: ReceiptReview.Row) -> some View {
        let name = row.itemID.flatMap { names[$0] }
        return HStack(spacing: 12) {
            Button { picking = row } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name ?? String(localized: "Pick an item"))
                        .font(.foonBody)
                        .foregroundStyle(name == nil ? .secondary : .primary)
                    Text(row.text)
                        .font(.foonCaption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name.map { Text("\($0), from \(row.text)") } ?? Text("Not recognized: \(row.text)"))
            .accessibilityHint(Text("Picks the item this line is"))
            Toggle(isOn: included(row)) {
                Text("Count \(row.text)")
            }
            .labelsHidden()
            .disabled(row.itemID == nil)
        }
    }

    private func included(_ row: ReceiptReview.Row) -> Binding<Bool> {
        Binding(get: { row.isIncluded }, set: { review.setIncluded(row.id, $0) })
    }
}

/// Picks the item a receipt line is: one of the household's, or a new one by name.
struct ReceiptItemPicker: View {
    let line: String
    let items: [ReceiptItem]
    let pick: (UUID) -> Void
    let addNew: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var shown: [ReceiptItem] {
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return typed.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    private var offersNew: Bool {
        !typed.isEmpty && !items.contains { $0.name.caseInsensitiveCompare(typed) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
                if offersNew {
                    Button { Task { await add() } } label: {
                        Label("Add \u{201C}\(typed)\u{201D} as a new item", systemImage: "plus.circle")
                    }
                    .disabled(isAdding)
                }
                ForEach(shown) { item in
                    Button(item.name) {
                        pick(item.id)
                        dismiss()
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Find or type an item"))
            .navigationTitle(line)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        errorMessage = await addNew(typed)
        if errorMessage == nil { dismiss() }
    }
}

#Preview("Review") {
    @Previewable @State var review = ReceiptReview(
        ReceiptMatcher.match(ReceiptFixtures.costco, items: ReceiptFixtures.items, aliases: [])
    )
    NavigationStack {
        ReceiptReviewView(review: $review, items: ReceiptFixtures.items)
            .navigationTitle("Scan a receipt")
    }
}

#Preview("Pick an item") {
    ReceiptItemPicker(line: "ROTISSERIE CHKN", items: ReceiptFixtures.items, pick: { _ in }, addNew: { _ in nil })
}
