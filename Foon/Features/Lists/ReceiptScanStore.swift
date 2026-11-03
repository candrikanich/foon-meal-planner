import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI

/// One receipt scan (#61): read the photo on the phone, review what it found, then Confirm marks it bought. Nothing
/// changes before Confirm, and Confirm goes through the sync queue, so it works in a parking lot with no signal.
@Observable @MainActor
final class ReceiptScanStore {
    enum Phase: Equatable { case choosing, reading, review, done }

    private(set) var phase: Phase = .choosing
    var review = ReceiptReview([])
    private(set) var boughtCount = 0
    /// "Keep apples on hand?", until each is answered.
    private(set) var suggestions: [UUID] = []
    private(set) var errorMessage: String?
    /// Items made during review, named here until the next pull brings them into the cache.
    private(set) var newItems: [ReceiptItem] = []

    let householdID: UUID
    private let client: ReceiptClient
    private let itemClient: ItemClient
    private let now: @Sendable () -> Date

    init(householdID: UUID, client: ReceiptClient, itemClient: ItemClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.householdID = householdID
        self.client = client
        self.itemClient = itemClient
        self.now = now
    }

    /// A preview or test can start at the review.
    convenience init(householdID: UUID, review: ReceiptReview) {
        self.init(householdID: householdID, client: .preview(), itemClient: .preview)
        self.review = review
        phase = .review
    }

    /// The pages are read here and let go: they're never uploaded, stored or cached (docs/spec.md → privacy, "receipt
    /// images deleted after parsing", met by never keeping one). Only the text goes on, and only to the matcher.
    func read(_ pages: [CGImage], items: [ReceiptItem]) async {
        errorMessage = nil
        phase = .reading
        var lines: [String] = []
        for page in pages { lines += await TextRecognizer.lines(in: page) }
        // Offline, what the family taught can't be fetched; the built-in matcher still reads the receipt.
        let aliases = (try? await client.aliases(householdID)) ?? []
        let matched = ReceiptMatcher.match(lines, items: items, aliases: aliases)
        guard !matched.isEmpty else {
            errorMessage = String(localized: "Couldn't find any groceries on that receipt. Try a flat, well-lit photo.")
            phase = .choosing
            return
        }
        review = ReceiptReview(matched)
        phase = .review
    }

    func failedToLoadPhoto() {
        errorMessage = String(localized: "Couldn't open that photo. Try another.")
    }

    /// A line taken as a brand-new item, made the way the list's Add an item makes one. Needs a connection. Nil when it
    /// worked, or what to say.
    func assign(_ rowID: Int, newItemNamed name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let id = try await itemClient.ensure(householdID, trimmed, ItemCategory.guess(for: trimmed) ?? .other)
            if !newItems.contains(where: { $0.id == id }) { newItems.append(ReceiptItem(id: id, name: trimmed)) }
            review.assign(rowID, to: id)
            return nil
        } catch {
            return OfflineReplay.classify(error) == .offline
                ? String(localized: "New items need a connection. Pick one you have, or try again.")
                : String(localized: "Couldn't add \(trimmed). Try again.")
        }
    }

    /// Marks it all bought: lines checked off, staples back in, corrections taught. Then offers staples.
    func confirm(sync: SyncService, entries: [ListEntry], stock: [UUID: ReceiptStock]) async {
        let bought = review.itemIDs
        await sync.perform(ReceiptApply.changes(itemIDs: bought, entries: entries, stock: stock,
                                                corrections: review.corrections, householdID: householdID))
        boughtCount = bought.count
        phase = .done
        if !newItems.isEmpty { await sync.pull() }
        // Offline there's no list history to ask, so nothing's suggested; the receipt itself is already marked.
        let before = (try? await client.checkedOff(householdID, bought, ReceiptStaples.window(endingAt: now()))) ?? []
        suggestions = ReceiptStaples.suggestions(bought: bought, stock: stock, boughtBefore: before)
    }

    func keepOnHand(_ itemID: UUID, sync: SyncService) async {
        suggestions.removeAll { $0 == itemID }
        await sync.setStock(itemID: itemID, state: .in)
    }

    func notNow(_ itemID: UUID) {
        suggestions.removeAll { $0 == itemID }
    }
}

/// A photo as a page to read: scaled to a size Vision reads well, the right way up.
enum ReceiptPhoto {
    static let maxPixels = 3000

    static func page(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            // Never write a thumbnail cache: the photo isn't kept anywhere.
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One sheet per scan: a new store is a new sheet.
extension ReceiptScanStore: Identifiable {}

extension EnvironmentValues {
    /// Set at the app root to the live client; previews use their own.
    @Entry var receiptClient = ReceiptClient.unconfigured
}
