import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Foon

struct PhotoPreparationTests {
    @Test func stripsLocationCameraAndCaptureDetails() throws {
        let original = try Self.photo(width: 400, height: 300, metadata: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.4993, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 81.6944, kCGImagePropertyGPSLongitudeRef: "W"
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:26 18:30:00"]
        ])
        #expect(Self.properties(of: original)[kCGImagePropertyGPSDictionary] != nil, "the fixture carries GPS")

        let prepared = try PhotoPreparation.prepare(original)
        let properties = Self.properties(of: prepared)

        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    @Test func outputsAJPEGNoLargerThanTheLimit() throws {
        let prepared = try PhotoPreparation.prepare(try Self.photo(width: 3000, height: 2000), maxPixelSize: 2048)
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = Self.properties(of: prepared)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2048)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1365)
    }

    @Test func bakesInOrientationSoNoTagIsNeeded() throws {
        // A landscape sensor image tagged "rotate 90°" (orientation 6) should come out portrait.
        let rotated = try Self.photo(width: 400, height: 300, metadata: [kCGImagePropertyOrientation: 6])
        let properties = Self.properties(of: try PhotoPreparation.prepare(rotated))
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 300)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 400)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: PhotoPreparation.Failure.notAnImage) {
            try PhotoPreparation.prepare(Data("not a photo".utf8))
        }
    }

    // MARK: - Fixtures

    private static func photo(width: Int, height: Int, metadata: [CFString: Any] = [:]) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }
}

struct PhotoStorageClientTests {
    @Test func mealPhotosLiveUnderTheHouseholdsFolder() throws {
        let household = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A0"))
        let photo = try #require(UUID(uuidString: "11111111-2222-3333-4444-55555555555A"))
        #expect(PhotoStorageClient.mealPhotoPath(householdID: household, photoID: photo)
            == "00000000-0000-0000-0000-0000000000a0/meals/11111111-2222-3333-4444-55555555555a.jpg")
    }
}
