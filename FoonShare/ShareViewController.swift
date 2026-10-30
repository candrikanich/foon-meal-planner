import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Foon" target: saves what was shared for the app to pick up, and closes. No network and no sign-in
/// here: extensions get little memory and time, and everything that can fail runs in the app (docs/spec.md → Share
/// Sheet extension).
final class ShareViewController: UIViewController {
    private let status = ShareStatus()
    private var didClose = false
    private var saving: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(status: status) { [weak self] in self?.close() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        saving = Task { await save() }
    }

    private func save() async {
        guard let inbox = SharedInbox.shared else {
            status.state = .failed
            return
        }
        do {
            guard let (kind, data) = try await shared() else {
                status.state = .unsupported
                return
            }
            // Cancel means cancel, even if the file took a while to arrive.
            try Task.checkCancellation()
            try inbox.add(SharedItem(kind: kind), fileData: data)
            status.state = .saved
            try? await Task.sleep(for: .seconds(1.2))
            close()
        } catch is SharedInbox.Full {
            status.state = .full
        } catch is TooBig {
            status.state = .tooBig
        } catch {
            status.state = .failed
        }
    }

    private struct TooBig: Error {}

    /// A web link if there is one (Safari also sends the page's text), then a PDF or photo, then text. A file's address
    /// counts as a public.url too, so it falls through to the file itself.
    private func shared() async throws -> (SharedItem.Kind, Data?)? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { item in (item.attachments ?? []).map { (item, $0) } }
        for (item, provider) in providers where provider.canLoadObject(ofClass: URL.self) {
            let title = item.attributedTitle?.string ?? item.attributedContentText?.string
            if let url = await loadURL(from: provider), let kind = SharedItem.Kind(url: url, title: title) {
                return (kind, nil)
            }
        }
        var couldntLoadAFile = false
        for (_, provider) in providers where provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let data = try await pdfData(from: provider) { return (.file(.pdf), data) }
            couldntLoadAFile = true
        }
        for (_, provider) in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await imageData(from: provider) { return (.file(.image), data) }
            couldntLoadAFile = true
        }
        for (_, provider) in providers where provider.canLoadObject(ofClass: String.self) {
            if let text = await loadText(from: provider), let kind = SharedItem.Kind(sharedText: text) {
                return (kind, nil)
            }
        }
        // We know what it was and failed to get it: not the same as something Foon can't use.
        if couldntLoadAFile { throw CocoaError(.fileReadUnknown) }
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

    /// The size is checked before reading, and the system's temporary copy only lasts for the callback.
    private func pdfData(from provider: NSItemProvider) async throws -> Data? {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data?, TooBig>, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: .success(nil)) }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= SharedItem.fileSizeLimit else { return continuation.resume(returning: .failure(TooBig())) }
                continuation.resume(returning: .success(try? Data(contentsOf: url, options: .mappedIfSafe)))
            }
        }
        return try result.get()
    }

    /// From a file if there is one; a screenshot's thumbnail may only offer the image itself.
    private func imageData(from provider: NSItemProvider) async -> Data? {
        let fromFile: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                continuation.resume(returning: url.flatMap(Self.downscaledJPEG(at:)))
            }
        }
        if let fromFile { return fromFile }
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: (object as? UIImage).flatMap(Self.downscaledJPEG(of:)))
            }
        }
    }

    /// Big enough to read, small enough for an extension's memory: ImageIO scales without loading the whole photo.
    private nonisolated static func downscaledJPEG(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels(of: source)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// 2400 on the long side, except a long scrolling screenshot, which keeps its width legible up to 6000.
    private nonisolated static func maxPixels(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let (long, short) = (max(width, height), min(width, height))
        guard short > 0 else { return 2400 }
        return min(long, max(2400, min(6000, 1200 * long / short)))
    }

    private nonisolated static func downscaledJPEG(of image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 2400 / (longest * image.scale))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        return (image.preparingThumbnail(of: size) ?? image).jpegData(compressionQuality: 0.8)
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        saving?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable @MainActor
final class ShareStatus {
    enum State {
        case saving, saved, unsupported, tooBig, full, failed
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
        case .unsupported: String(localized: "Foon can use a link, some text, a photo, or a PDF.")
        case .tooBig: String(localized: "That PDF is too big for Foon. Try a smaller one.")
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
