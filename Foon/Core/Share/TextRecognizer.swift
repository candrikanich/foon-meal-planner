import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads text from a photo or PDF on this device (docs/spec.md → privacy: nothing leaves the phone). A PDF's own text
/// is used when it has some; a scanned one is rendered and read like a photo. Empty when there's nothing to read.
enum TextRecognizer {
    /// A long PDF is usually not a recipe; the first pages are enough, and it keeps the work bounded.
    static let pageLimit = 10
    /// A page's size says nothing about its file size: a tiny PDF can declare a huge page. Same as a shared photo.
    static let renderLimit = 2400.0
    /// Less than this of a page's own text is a scanner's watermark or a page number, so the page is read as a picture.
    private static let ownTextMinimum = 40

    static func lines(in url: URL, type: SharedItem.FileType) async -> [String] {
        switch type {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            return await lines(in: image)
        case .pdf:
            guard let document = PDFDocument(url: url) else { return [] }
            var lines: [String] = []
            for index in 0..<min(document.pageCount, pageLimit) where !Task.isCancelled {
                guard let page = document.page(at: index) else { continue }
                let text = page.string ?? ""
                let own = text.split(whereSeparator: \.isNewline).map(String.init)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= ownTextMinimum {
                    lines += own
                } else {
                    let read = if let image = autoreleasepool(invoking: { rendered(page) }) { await self.lines(in: image) } else { [String]() }
                    lines += read.isEmpty ? own : read
                }
            }
            return lines
        }
    }

    static func lines(in image: CGImage) async -> [String] {
        let request = RecognizeTextRequest()
        let observations = (try? await request.perform(on: image)) ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    static func renderScale(for size: CGSize) -> Double {
        let longest = max(size.width, size.height)
        return longest > 0 ? min(2, renderLimit / longest) : 2
    }

    private static func rendered(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = renderScale(for: bounds.size)
        let size = (width: Int(bounds.width * scale), height: Int(bounds.height * scale))
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
