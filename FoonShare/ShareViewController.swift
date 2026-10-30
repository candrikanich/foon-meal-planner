import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Foon" target: saves what was shared for the app to pick up, and closes. No network and no sign-in
/// here: extensions get little memory and time, and everything that can fail runs in the app (docs/spec.md → Share
/// Sheet extension).
final class ShareViewController: UIViewController {
    private let status = ShareStatus()
    private var didClose = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(status: status) { [weak self] in self?.close() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await save() }
    }

    private func save() async {
        guard let kind = await sharedKind() else {
            status.state = .unsupported
            return
        }
        guard let inbox = SharedInbox.shared else {
            status.state = .failed
            return
        }
        do {
            try inbox.add(SharedItem(kind: kind))
            status.state = .saved
            try? await Task.sleep(for: .seconds(1.2))
            close()
        } catch is SharedInbox.Full {
            status.state = .full
        } catch {
            status.state = .failed
        }
    }

    /// A web link if there is one (Safari also sends the page's text), otherwise the text.
    private func sharedKind() async -> SharedItem.Kind? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            let title = item.attributedTitle?.string ?? item.attributedContentText?.string
            for provider in item.attachments ?? [] where provider.canLoadObject(ofClass: URL.self) {
                if let url = await loadURL(from: provider), let kind = SharedItem.Kind(url: url, title: title) {
                    return kind
                }
            }
        }
        for item in items {
            for provider in item.attachments ?? [] where provider.canLoadObject(ofClass: String.self) {
                if let text = await loadText(from: provider), let kind = SharedItem.Kind(sharedText: text) {
                    return kind
                }
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable @MainActor
final class ShareStatus {
    enum State {
        case saving, saved, unsupported, full, failed
    }

    var state = State.saving
}

struct ShareStatusView: View {
    let status: ShareStatus
    let close: () -> Void

    private var message: String {
        switch status.state {
        case .saving: String(localized: "Saving to Foon…")
        case .saved: String(localized: "Saved. Open Foon to finish.")
        case .unsupported: String(localized: "Foon can use links and text for now.")
        case .full: String(localized: "Foon has a lot waiting. Open Foon, then share this again.")
        case .failed: String(localized: "Couldn't save that. Try again.")
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            if status.state == .saving { ProgressView() }
            Text(message).font(.headline).multilineTextAlignment(.center)
            Button(status.state == .saving ? "Cancel" : "Done", action: close)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Saved") {
    let status = ShareStatus()
    status.state = .saved
    return ShareStatusView(status: status) {}
}

#Preview("Saving") {
    ShareStatusView(status: ShareStatus()) {}
}
