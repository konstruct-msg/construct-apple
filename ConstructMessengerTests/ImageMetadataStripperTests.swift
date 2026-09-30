//
//  ImageMetadataStripperTests.swift
//  ConstructMessengerTests
//
//  An original-quality photo keeps its pixels and orientation and loses where, when and with
//  what it was taken. The source is written the way a camera writes it.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Construct_Messenger

final class ImageMetadataStripperTests: XCTestCase {

    func testJPEGLosesLocationTimeAndCameraButKeepsOrientationAndPixels() throws {
        try assertStripped(type: .jpeg)
    }

    func testPNGLosesLocationTimeAndCamera() throws {
        try assertStripped(type: .png)
    }

    func testHEICLosesLocationTimeAndCamera() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true
        else { throw XCTSkip("no HEIC encoder on this runtime") }
        try assertStripped(type: .heic)
    }

    func testDataThatIsNotAnImageIsRefused() {
        XCTAssertNil(ImageMetadataStripper.strip(Data("not an image".utf8)))
    }

    private func assertStripped(type: UTType, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try Self.cameraImage(type: type)
        let before = try XCTUnwrap(Self.properties(source))
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "the source must carry GPS, or this proves nothing", file: file, line: line)

        let stripped = try XCTUnwrap(ImageMetadataStripper.strip(source), file: file, line: line)
        XCTAssertTrue(ImageMetadataStripper.carriesNothingButThePicture(stripped), "\(type): \(Self.properties(stripped) ?? [:])", file: file, line: line)
        XCTAssertFalse(ImageMetadataStripper.carriesNothingButThePicture(source), "the check must see the source's metadata", file: file, line: line)
        let after = try XCTUnwrap(Self.properties(stripped), file: file, line: line)
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "\(type): GPS survived", file: file, line: line)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "\(type): capture time survived", file: file, line: line)
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "\(type): camera model survived", file: file, line: line)
        if type != .png {
            XCTAssertEqual(after[kCGImagePropertyOrientation] as? Int, 6, "\(type): orientation lost", file: file, line: line)
        }
        XCTAssertEqual(after[kCGImagePropertyPixelWidth] as? Int, 48, file: file, line: line)
        XCTAssertEqual(after[kCGImagePropertyPixelHeight] as? Int, 32, file: file, line: line)
    }

    private static func properties(_ data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    /// 48×32, orientation 6, with a GPS position, a capture time and a camera model.
    private static func cameraImage(type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let image = try XCTUnwrap(context.makeImage())

        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 40.1792, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 44.4991, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:30 12:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera", kCGImagePropertyTIFFOrientation: 6],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
