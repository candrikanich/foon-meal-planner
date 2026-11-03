import PhotosUI
import SwiftData
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Lists → Scan a receipt (docs/spec.md → Receipts): take or pick a photo, check what Foon read, then Confirm marks it
/// bought. Anyone in the family can, kids too, as anyone can check things off.
struct ReceiptScanView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    @Environment(\.dismiss) private var dismiss
    @Query private var lines: [CachedListItem]
    @Query private var cached: [CachedItem]
    @State private var store: ReceiptScanStore
    @State private var photo: PhotosPickerItem?
    @State private var usingCamera = false
    @State private var isConfirming = false

    init(store: ReceiptScanStore) {
        _store = State(initialValue: store)
    }

    private var items: [ReceiptItem] {
        let known = cached.map { ReceiptItem(id: $0.id, name: $0.name) }
        let ids = Set(known.map(\.id))
        return known + store.newItems.filter { !ids.contains($0.id) }
    }

    private var stock: [UUID: ReceiptStock] {
        Dictionary(cached.map { ($0.id, ReceiptStock(keepOnHand: $0.keepOnHand, state: $0.stockState)) },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan a receipt")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
        }
        .onChange(of: photo) { _, picked in
            guard let picked else { return }
            Task { await read(picked) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $usingCamera) {
            DocumentCamera { pages in
                usingCamera = false
                Task { await store.read(pages, items: items) }
            } onCancel: {
                usingCamera = false
            }
            .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .choosing: choosing
        case .reading:
            ProgressView("Reading the receipt\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            ReceiptReviewView(review: $store.review, items: items) { rowID, name in
                await store.assign(rowID, newItemNamed: name)
            }
        case .done: ReceiptDoneView(store: store, items: items)
        }
    }

    private var choosing: some View {
        List {
            Section {
                #if os(iOS)
                if VNDocumentCameraViewController.isSupported {
                    Button { usingCamera = true } label: {
                        Label("Take a photo", systemImage: "camera")
                    }
                }
                #endif
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                }
            } footer: {
                Text("Foon reads the receipt on this device and doesn't keep the photo. You'll check what it found before anything changes.")
            }
            if let message = store.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch store.phase {
        case .done:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        case .review:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") { Task { await confirm() } }
                    .disabled(store.review.itemIDs.isEmpty || isConfirming || sync == nil)
                    .accessibilityHint(Text("Marks these bought and checks them off the lists"))
            }
        case .choosing, .reading:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func read(_ picked: PhotosPickerItem) async {
        photo = nil
        // Loaded into memory only for the read: never written to disk, uploaded, or kept once this returns.
        guard let data = try? await picked.loadTransferable(type: Data.self), let page = ReceiptPhoto.page(from: data) else {
            store.failedToLoadPhoto()
            return
        }
        await store.read([page], items: items)
    }

    private func confirm() async {
        guard let sync else { return }
        isConfirming = true
        defer { isConfirming = false }
        await store.confirm(sync: sync, entries: ListEntry.entries(lines: lines, items: cached), stock: stock)
    }
}

/// After Confirm: what was marked, and "Keep apples on hand?" for things the family keeps buying.
struct ReceiptDoneView: View {
    @Environment(SyncService.self) private var sync: SyncService?
    let store: ReceiptScanStore
    let items: [ReceiptItem]

    private func name(_ itemID: UUID) -> String {
        items.first { $0.id == itemID }?.name ?? String(localized: "this")
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text("^[\(store.boughtCount) item](inflect: true) marked bought")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.herb)
                }
            } footer: {
                Text("They're checked off the lists, and staples are back in stock.")
            }
            if !store.suggestions.isEmpty {
                Section {
                    ForEach(store.suggestions, id: \.self) { itemID in suggestion(itemID) }
                } header: {
                    Text("Bought again")
                } footer: {
                    Text("Staples show under Keep on hand, so anyone can mark them low or out.")
                }
            }
        }
    }

    private func suggestion(_ itemID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep \(name(itemID)) on hand?").font(.foonBody)
            HStack {
                Button("Yes") {
                    guard let sync else { return }
                    Task { await store.keepOnHand(itemID, sync: sync) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.herb)
                .accessibilityLabel(Text("Keep \(name(itemID)) on hand"))
                Button("Not now") { store.notNow(itemID) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text("Not now for \(name(itemID))"))
            }
        }
        .padding(.vertical, 4)
    }
}

#if os(iOS)
/// The system's document camera: it finds the receipt's edges and flattens it, which Vision reads far better than a
/// plain photo. Its pages come back in memory only.
struct DocumentCamera: UIViewControllerRepresentable {
    let onScan: ([CGImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([CGImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([CGImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}
#endif

#Preview("Choose") {
    ReceiptScanView(store: ReceiptScanStore(householdID: Household.sample.id, client: .preview(), itemClient: .preview))
        .modelContainer(try! SyncService.inMemoryContainer())
}

#Preview("Done") {
    NavigationStack {
        ReceiptDoneView(store: ReceiptScanStore(householdID: Household.sample.id, review: ReceiptReview([])),
                        items: ReceiptFixtures.items)
    }
}

#Preview("Review") {
    ReceiptScanView(store: ReceiptScanStore(
        householdID: Household.sample.id,
        review: ReceiptReview(ReceiptMatcher.match(ReceiptFixtures.walmart, items: ReceiptFixtures.items, aliases: []))
    ))
    .modelContainer(try! SyncService.inMemoryContainer())
}
