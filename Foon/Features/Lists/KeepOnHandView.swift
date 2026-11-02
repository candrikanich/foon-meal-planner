import SwiftData
import SwiftUI

/// The keep-on-hand list (docs/spec.md → Keep-on-hand list): each staple is in, low, or out, no counting, and anyone can say so.
/// Out goes straight on the quick list; low shows under Staples running low on Lists. Both go on the next weekly list. They notify no one.
struct KeepOnHandView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(HouseholdStore.self) private var household
    @Environment(\.itemClient) private var itemClient
    @Query private var items: [CachedItem]
    @State private var newStaple = ""
    @State private var errorMessage: String?

    /// Plain values, since a pull replaces the cached rows while these closures are still around to be tapped. By name alone, so
    /// a row doesn't jump away from the thumb that just tapped it.
    private struct Staple: Identifiable {
        let id: UUID
        let name: String
        let state: StockState
    }

    private var staples: [Staple] {
        items.filter(\.keepOnHand)
            .map { Staple(id: $0.id, name: $0.name, state: $0.stockState ?? .in) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        let staples = staples
        List {
            Section {
                TextField("Add a staple", text: $newStaple)
                    .onSubmit { Task { await add() } }
                    .submitLabel(.done)
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Cereal, milk, paper towels: what you never want to run out of. Several at once: separate them with commas.")
            }
            Section {
                if staples.isEmpty {
                    Text("No staples yet.").foregroundStyle(.secondary)
                }
                ForEach(staples) { staple in
                    row(staple)
                        .swipeActions(edge: .trailing) {
                            Button("Stop keeping", systemImage: "minus.circle", role: .destructive) { set(staple.id, to: nil) }
                        }
                        .accessibilityAction(named: Text("Stop keeping")) { set(staple.id, to: nil) }
                }
            } footer: {
                if !staples.isEmpty {
                    Text("Out goes straight on the list. Low shows under Staples running low on Lists, and goes on the next weekly list.")
                }
            }
        }
        .navigationTitle("Keep on hand")
        .refreshable { await sync?.pull() }
    }

    private func row(_ staple: Staple) -> some View {
        let state = Binding(get: { staple.state }, set: { set(staple.id, to: $0) })
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(staple.name)
                Spacer()
                StockPicker(state: state, name: staple.name).frame(width: 170)
            }
            VStack(alignment: .leading) {
                Text(staple.name)
                StockPicker(state: state, name: staple.name)
            }
        }
    }

    private func set(_ itemID: UUID, to state: StockState?) {
        Task { await sync?.setStock(itemID: itemID, state: state) }
    }

    /// The name as typed: a staple's name stays for good, and "7 Up" isn't seven of anything. Commas or new lines separate.
    nonisolated static func names(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Known items work offline; a brand-new one needs a connection to be created first. What couldn't be added stays in the field.
    private func add() async {
        let names = Self.names(in: newStaple)
        guard let sync, !names.isEmpty, let householdID = household.household?.id else { return }
        let known = Dictionary(items.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        var itemIDs: [UUID] = []
        var failed: [String] = []
        var offline = false
        var created = false
        for name in names {
            if let id = known[name.lowercased()] {
                itemIDs.append(id)
                continue
            }
            do {
                itemIDs.append(try await itemClient.ensure(householdID, name, ItemCategory.guess(for: name) ?? .other))
                created = true
            } catch {
                failed.append(name)
                if OfflineReplay.classify(error) == .offline { offline = true }
            }
        }
        // "New" may only mean new to this phone: pull first, so a staple someone marked out doesn't go back to in.
        if created { await sync.pull() }
        for id in itemIDs where sync.isKeptOnHand(id) != true {
            await sync.perform(.setStock(itemID: id, state: .in))
        }
        newStaple = failed.joined(separator: ", ")
        let list = failed.formatted(.list(type: .and))
        errorMessage = failed.isEmpty ? nil : offline
            ? String(localized: "Couldn't add \(list). New items need a connection; try again.")
            : String(localized: "Couldn't add \(list). Try again.")
        if created { await sync.pull() }
    }
}

#Preview {
    NavigationStack { KeepOnHandView() }
        .environment(HouseholdStore.preview())
        .modelContainer(try! SyncService.inMemoryContainer())
}
