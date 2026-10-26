import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a photo safe and small enough to upload: redraws it into a fresh JPEG, which drops every
/// metadata block (GPS location, camera, capture time), bakes in its orientation, and caps its size.
/// Family photos never leave the device with location data (spec: "Strip location and other
/// metadata from every uploaded photo").
enum PhotoPreparation {
    enum Failure: Error, Equatable {
        case notAnImage
        case encodingFailed
    }

    static func prepare(_ data: Data, maxPixelSize: Int = 2048, quality: Double = 0.8) throws(Failure) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary)
        else { throw .notAnImage }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw .encodingFailed }
        // Only the compression setting goes in: no metadata is copied from the original.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodingFailed }
        return output as Data
    }
}
