import Foundation
import Photos
import SwiftUI

/// Whether Foon can read this device's photo library.
enum PhotoAccess: Equatable, Sendable {
    case notAsked
    case full
    /// Only the photos the person picked for Foon.
    case limited
    /// Said no, or a parent or profile restricts it. Only Settings can change it.
    case refused

    var canRead: Bool { self == .full || self == .limited }
}

/// The photo library, as closures, so tests and previews never touch it. Works the same on iOS and macOS.
struct PhotoLibrarySource: Sendable {
    var access: @Sendable () -> PhotoAccess
    /// Asks the system once. Returns what the person chose.
    var requestAccess: @Sendable () async -> PhotoAccess
    /// The still photos (no videos, screenshots or hidden photos) taken inside any of these windows.
    var photos: @Sendable (_ windows: [DateInterval]) async -> [PhotoStamp]
    /// One photo, drawn at about this size in points, for the screen. Nil if it can't be read.
    var image: @Sendable (_ id: String, _ size: CGSize) async -> Image?
}

extension PhotoLibrarySource {
    static let system = PhotoLibrarySource(
        access: { PhotoReader.currentAccess() },
        requestAccess: {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return PhotoReader.currentAccess()
        },
        photos: { windows in PhotoReader.photos(in: windows) },
        image: { id, size in await PhotoReader.image(id, size: size) }
    )

    static let none = PhotoLibrarySource(access: { .notAsked }, requestAccess: { .refused }, photos: { _ in [] },
                                         image: { _, _ in nil })
}

/// Each PhotoKit object is turned into an identifier and a date, or into an image for the screen, right here and
/// dropped. Nothing read is saved, cached, synced, logged, counted or uploaded (CLAUDE.md rule 4): the library is
/// read fresh each time the timeline opens or pages back.
private enum PhotoReader {
    static func currentAccess() -> PhotoAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notAsked
        case .denied, .restricted: .refused
        @unknown default: .refused
        }
    }

    /// One fetch per window, so only photos around dinner are ever read, not the whole range between them. Stops
    /// between windows once the read is cancelled (the screen closed, or the switch went off).
    static func photos(in windows: [DateInterval]) -> [PhotoStamp] {
        guard currentAccess().canRead else { return [] }
        var stamps: [PhotoStamp] = []
        for window in windows {
            if Task.isCancelled { break }
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@ AND (mediaSubtypes & %d) == 0",
                window.start as NSDate, window.end as NSDate, PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
                if let created = asset.creationDate {
                    stamps.append(PhotoStamp(id: asset.localIdentifier, createdAt: created))
                }
            }
        }
        return stamps
    }

    /// Cancelled when its thumbnail scrolls away or the screen closes, so a fast scroll doesn't leave a queue of
    /// decodes and iCloud downloads running.
    static func image(_ id: String, size: CGSize) async -> Image? {
        guard currentAccess().canRead,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        // One answer, not a blurry one first.
        options.deliveryMode = .highQualityFormat
        // Decoded at the target size, not whatever size is quickest to hand.
        options.resizeMode = .exact
        // Photos kept in iCloud come down to this device the way the Photos app fetches them; Foon sends nothing.
        options.isNetworkAccessAllowed = true
        let scale = 3.0
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let request = ImageRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation) { finish in
                    PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill,
                                                          options: options) { picture, _ in
                        #if canImport(UIKit)
                        finish(picture.map { Image(uiImage: $0) })
                        #else
                        finish(picture.map { Image(nsImage: $0) })
                        #endif
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }
}

/// One image request. Its continuation resumes exactly once, whether PhotoKit answers, the task is cancelled first,
/// or the two race: PhotoKit may or may not call back after `cancelImageRequest`, so whichever comes first wins.
private final class ImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Image?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<Image?, Never>,
               request: (_ finish: @escaping @Sendable (Image?) -> Void) -> PHImageRequestID) {
        let alreadyCancelled = lock.withLock {
            if !cancelled { self.continuation = continuation }
            return cancelled
        }
        guard !alreadyCancelled else { return continuation.resume(returning: nil) }
        let id = request { [self] image in finish(image) }
        let cancelledMeanwhile = lock.withLock {
            requestID = id
            return cancelled
        }
        if cancelledMeanwhile { PHImageManager.default().cancelImageRequest(id) }
    }

    func cancel() {
        let id = lock.withLock {
            cancelled = true
            return requestID
        }
        if let id { PHImageManager.default().cancelImageRequest(id) }
        finish(nil)
    }

    private func finish(_ image: Image?) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: image)
    }
}
