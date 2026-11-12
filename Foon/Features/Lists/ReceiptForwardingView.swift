import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Lists → Forward receipts by email (docs/spec.md → Receipts), adults only: the family's address to forward store
/// receipt emails to, and the addresses this adult forwards from, each confirmed by a link Foon emails it.
struct ReceiptForwardingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ReceiptForwardingStore
    @State private var typed = ""
    @State private var confirmingReset = false
    /// Adding an address and changing the family's are blocked while the household has lapsed.
    let canEdit: Bool

    init(store: ReceiptForwardingStore, canEdit: Bool) {
        _store = State(initialValue: store)
        self.canEdit = canEdit
    }

    var body: some View {
        List {
            addressSection
            if let notice = store.notice {
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(notice.isProblem ? Color.red : Color.secondary)
            }
            sendersSection
            addSection
            Section {
                Button("Get a new address", role: .destructive) { confirmingReset = true }
                    .disabled(!canEdit || store.isWorking || store.address == nil)
            }
        }
        .navigationTitle("Forward receipts")
        .refreshable { await store.load() }
        .task { await store.load() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.load() }
        }
        .confirmationDialog("Get a new address?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Get a new address", role: .destructive) { Task { await store.resetAddress() } }
        } message: {
            Text("The old address stops working. Anyone forwarding to it will need the new one.")
        }
    }

    private var addressSection: some View {
        Section {
            if let address = store.address {
                Text(address)
                    .font(.foonBody.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel(Text("Your family's receipt address: \(address)"))
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { copy(address) }
                        .accessibilityLabel(Text("Copy the address"))
                    Spacer()
                    ShareLink(item: address) { Label("Share", systemImage: "square.and.arrow.up") }
                        .accessibilityLabel(Text("Share the address"))
                }
                .buttonStyle(.borderless)
            } else {
                ProgressView()
            }
        } header: {
            Text("Your family's address")
        } footer: {
            Text("Forward a store's receipt email to this address from one of your addresses below. Foon reads the items and asks you to check them, like a scanned receipt.")
        }
    }

    @ViewBuilder
    private var sendersSection: some View {
        Section {
            if store.senders.isEmpty {
                Text("None yet. Add the address your store receipts go to.").foregroundStyle(.secondary)
            }
            ForEach(store.senders) { sender in
                ReceiptSenderRow(sender: sender)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await store.remove(sender) }
                        }
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await store.remove(sender) }
                        }
                    }
                    .accessibilityAction(named: Text("Remove")) { Task { await store.remove(sender) } }
            }
        } header: {
            Text("Addresses you forward from")
        }
    }

    private var addSection: some View {
        Section {
            TextField("Email address", text: $typed)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.send)
                .onSubmit { Task { await add() } }
                .disabled(!canEdit)
            Button("Send a link to confirm it") { Task { await add() } }
                .disabled(!canEdit || store.isWorking || typed.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Add an address")
        } footer: {
            Text("Foon emails it a link to confirm it's yours, and keeps only a hint of it.")
        }
    }

    private func add() async {
        if await store.add(typed) { typed = "" }
    }

    private func copy(_ address: String) {
        #if os(iOS)
        UIPasteboard.general.string = address
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
    }
}

/// One forwarding address: its hint, and whether it's confirmed yet.
struct ReceiptSenderRow: View {
    let sender: ReceiptSender

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sender.addressHint).font(.foonBody)
            if sender.isConfirmed {
                Label("Confirmed", systemImage: "checkmark.circle.fill")
                    .font(.foonCaption)
                    .foregroundStyle(Palette.herb)
            } else {
                Label("Waiting for you to confirm", systemImage: "envelope.badge")
                    .font(.foonCaption)
                    .foregroundStyle(Palette.caution)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        ReceiptForwardingView(
            store: ReceiptForwardingStore(householdID: Household.sample.id, memberID: UUID(),
                                          client: .preview(senders: ReceiptFixtures.senders)),
            canEdit: true
        )
    }
}
