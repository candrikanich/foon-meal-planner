import SwiftUI

/// An item's name with its standing note underneath ("Vanilla, not plain"). The same label serves
/// meals, lists, and store mode, so a preference is seen wherever the item is.
struct ItemLabel: View {
    let name: String
    let note: String?
    var quantity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let quantity {
                    Text(quantity).foregroundStyle(.secondary)
                }
                Text(name).foregroundStyle(Palette.ink)
            }
            .font(.foonBody)
            if let note {
                Label(note, systemImage: "text.bubble")
                    .font(.foonCaption)
                    .foregroundStyle(Palette.herb)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension EnvironmentValues {
    /// Set at the app root to the live client; previews use this one.
    @Entry var itemClient = ItemClient.unconfigured
}

/// One item: its note or brand preference (anyone at home), keep on hand (anyone), and category (planners).
struct ItemSheet: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @State private var store: ItemStore?
    let item: ItemDetails
    let canRecategorize: Bool
    let client: ItemClient
    let onSaved: () async -> Void

    var body: some View {
        if let store {
            ItemForm(store: store, onSaved: onSaved)
        } else {
            ProgressView().task { makeStore() }
        }
    }

    /// Built once the environment is readable: keep on hand needs the sync service and its cache.
    private func makeStore() {
        let sync = sync
        let store = ItemStore(item: item, canRecategorize: canRecategorize, client: client, queueStock: sync.map { sync in
            { keep in await sync.perform(.setStock(itemID: item.id, state: keep ? .in : nil)) }
        })
        if let cached = sync?.isKeptOnHand(item.id) { store.startFromCache(keepOnHand: cached) }
        self.store = store
    }
}

private struct ItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ItemStore
    let onSaved: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vanilla, not plain", text: $store.note, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityLabel("Note or brand")
                } header: {
                    Text("Note or brand")
                } footer: {
                    Text("Shown with \(store.item.name) on meals, lists, and in the store.")
                }

                Section {
                    if store.canRecategorize {
                        Picker("Aisle", selection: $store.category) {
                            ForEach(ItemCategory.storeOrder, id: \.self) { category in
                                Label(category.title, systemImage: category.systemImage).tag(category)
                            }
                        }
                    } else {
                        LabeledContent("Aisle", value: store.category.title)
                    }
                    if store.canKeepOnHand {
                        Toggle("Keep on hand", isOn: $store.keepOnHand)
                    }
                } footer: {
                    if store.canKeepOnHand {
                        Text("Staples like milk or paper towels stay on the keep-on-hand list, marked in, low, or out.")
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(store.item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(store.isSaving)
                }
            }
        }
    }

    private func save() async {
        guard await store.save() else { return }
        await onSaved()
        dismiss()
    }
}

#Preview("Item sheet") {
    ItemSheet(item: ItemDetails(id: UUID(), name: "Yogurt", category: .dairyEggs, note: "Vanilla, not plain",
                                keepOnHand: true),
              canRecategorize: true, client: .preview, onSaved: {})
}

#Preview("Labels") {
    List {
        ItemLabel(name: "Yogurt", note: "Vanilla, not plain", quantity: "2 cups")
        ItemLabel(name: "Paper towels", note: "store brand")
        ItemLabel(name: "Ground beef", note: nil, quantity: "1 lb")
    }
}
