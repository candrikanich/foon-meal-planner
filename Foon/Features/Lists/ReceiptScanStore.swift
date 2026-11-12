import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI

/// One receipt scan (#61): read the photo on the phone, review what it found, then Confirm marks it bought. Nothing
/// changes before Confirm, and Confirm goes through the sync queue, so it works in a parking lot with no signal.
/// A forwarded receipt email (#237) skips the photo: its lines go straight to the same matcher and review.
@Observable @MainActor
final class ReceiptScanStore {
    enum Phase: Equatable { case choosing, reading, review, done }

    enum Source: Equatable {
        case photo
        case forwarded(ForwardedReceipt)
    }

    private(set) var phase: Phase = .choosing
    var review = ReceiptReview([])
    private(set) var boughtCount = 0
    /// "Keep apples on hand?", until each is answered.
    private(set) var suggestions: [UUID] = []
    private(set) var errorMessage: String?
    /// Items made during review, named here until the next pull brings them into the cache.
    private(set) var newItems: [ReceiptItem] = []
    /// After Confirm, when a forwarded receipt was marked but couldn't be cleared from Lists.
    private(set) var clearMessage: String?

    let householdID: UUID
    let source: Source
    private let client: ReceiptClient
    private let itemClient: ItemClient
    private let forwardedClient: ForwardedReceiptClient
    private let now: @Sendable () -> Date

    init(householdID: UUID, client: ReceiptClient, itemClient: ItemClient, source: Source = .photo,
         forwardedClient: ForwardedReceiptClient = .unconfigured, now: @escaping @Sendable () -> Date = { Date() }) {
        self.householdID = householdID
        self.client = client
        self.itemClient = itemClient
        self.source = source
        self.forwardedClient = forwardedClient
        self.now = now
        if case .forwarded = source { phase = .reading }
    }

    private var forwarded: ForwardedReceipt? {
        if case .forwarded(let receipt) = source { receipt } else { nil }
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
        let nothingFound = String(localized: "Couldn't find any groceries on that receipt. Try a flat, well-lit photo.")
        await match(lines, items: items, nothingFound: nothingFound)
    }

    /// A forwarded receipt's lines, already read from the email by the server, matched like a photo's.
    func readForwarded(items: [ReceiptItem]) async {
        guard let forwarded else { return }
        errorMessage = nil
        phase = .reading
        await match(forwarded.lines, items: items,
                    nothingFound: String(localized: "Foon couldn't find any groceries in that email."))
    }

    private func match(_ lines: [String], items: [ReceiptItem], nothingFound: String) async {
        // Offline, what the family taught can't be fetched; the built-in matcher still reads the receipt.
        let aliases = (try? await client.aliases(householdID)) ?? []
        let matched = ReceiptMatcher.match(lines, items: items, aliases: aliases)
        guard !matched.isEmpty else {
            errorMessage = nothingFound
            phase = .choosing
            return
        }
        review = ReceiptReview(matched)
        phase = .review
    }

    /// Clears a forwarded receipt without changing anything. True once it's gone; otherwise says why and keeps it.
    func dismissForwarded() async -> Bool {
        guard let forwarded else { return true }
        do {
            try await forwardedClient.delete(forwarded.id)
            return true
        } catch {
            errorMessage = OfflineReplay.classify(error) == .offline
                ? String(localized: "Dismissing needs a connection. Try again when you're online.")
                : String(localized: "Couldn't dismiss it. Try again.")
            return false
        }
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
        await clearForwarded()
        if !newItems.isEmpty { await sync.pull() }
        // Offline there's no list history to ask, so nothing's suggested; the receipt itself is already marked.
        let before = (try? await client.checkedOff(householdID, bought, ReceiptStaples.window(endingAt: now()))) ?? []
        suggestions = ReceiptStaples.suggestions(bought: bought, stock: stock, boughtBefore: before)
    }

    /// A confirmed forwarded receipt leaves Lists. If that fails it stays; what was bought is already checked off
    /// through the sync queue, so the message says to dismiss it rather than confirm it again.
    private func clearForwarded() async {
        guard let forwarded else { return }
        do {
            try await forwardedClient.delete(forwarded.id)
        } catch {
            clearMessage = OfflineReplay.classify(error) == .offline
                ? String(localized: "Couldn't clear it from the list. Dismiss it from Lists when you're online.")
                : String(localized: "Couldn't clear it from the list. Dismiss it from Lists later.")
        }
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
    @Entry var forwardedReceiptClient = ForwardedReceiptClient.unconfigured
}
