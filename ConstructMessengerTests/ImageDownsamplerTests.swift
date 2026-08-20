//
//  ImageDownsamplerTests.swift
//  ConstructMessengerTests
//
//  2026-08-10: nothing in the app downsampled. Every display path decoded at full resolution via
//  `UIImage(data:)`, so a chat bubble ~300pt wide held the 1440×2048 bitmap of the photo that was
//  sent — ~11.8 MB where ~4 MB would do, and that was before the cache held onto it. Device
//  footprint went 127 MB → 447 MB over nine minutes of ordinary chatting.
//

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Construct_Messenger

final class ImageDownsamplerTests: XCTestCase {

    // MARK: - The pixel budget

    func testBudgetFollowsTheScreenScale() {
        // A 300pt bubble on a 3× phone needs 900px, not the 3-megapixel original.
        XCTAssertEqual(ImageDownsampler.pixelBudget(forPoints: 300, scale: 3), 900)
        XCTAssertEqual(ImageDownsampler.pixelBudget(forPoints: 300, scale: 2), 600)
    }

    func testBudgetIsCapped() {
        // An iPad bubble must not talk us back into a full-resolution decode.
        XCTAssertEqual(
            ImageDownsampler.pixelBudget(forPoints: 2000, scale: 3),
            ImageDownsampler.bubbleMaxPixelSize
        )
    }

    func testDegenerateGeometryFallsBackToTheCap() {
        // Layout can report zero before the first pass; a budget of 0 would decode nothing.
        XCTAssertEqual(ImageDownsampler.pixelBudget(forPoints: 0, scale: 3),
                       ImageDownsampler.bubbleMaxPixelSize)
        XCTAssertEqual(ImageDownsampler.pixelBudget(forPoints: 300, scale: 0),
                       ImageDownsampler.bubbleMaxPixelSize)
    }

    func testFractionalPointsRoundUp() {
        // Rounding down would leave a bubble one pixel short of its own width — visible as soft
        // edges on exactly the devices where people notice.
        XCTAssertEqual(ImageDownsampler.pixelBudget(forPoints: 100.4, scale: 3), 302)
    }

    #if canImport(UIKit)

    // MARK: - The decode

    /// A photo the size of the one in the incident, as JPEG.
    private func photoData(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // Gradient rather than flat fill: a solid colour compresses to almost nothing and
            // would not exercise a realistic decode.
            for y in stride(from: 0, to: height, by: 8) {
                UIColor(hue: CGFloat(y) / CGFloat(height), saturation: 0.8, brightness: 0.9, alpha: 1)
                    .setFill()
                ctx.fill(CGRect(x: 0, y: y, width: width, height: 8))
            }
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        return data
    }

    func testALargePhotoDecodesToTheBudgetNotItsOwnSize() throws {
        let data = try photoData(width: 1440, height: 2048)   // the size from the device log

        let full = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(Int(full.size.height), 2048, "sanity: the fixture really is full-size")

        let downsampled = try XCTUnwrap(ImageDownsampler.image(from: data, maxPixelSize: 1024))
        let longest = max(downsampled.size.width, downsampled.size.height) * downsampled.scale
        XCTAssertLessThanOrEqual(Int(longest), 1024)
    }

    func testAspectRatioSurvives() throws {
        let data = try photoData(width: 1440, height: 2048)
        let downsampled = try XCTUnwrap(ImageDownsampler.image(from: data, maxPixelSize: 1024))
        let ratio = downsampled.size.width / downsampled.size.height
        XCTAssertEqual(ratio, 1440.0 / 2048.0, accuracy: 0.01, "a squashed photo is worse than a big one")
    }

    func testAnImageSmallerThanTheBudgetIsNotUpscaled() throws {
        // Thumbnails and stickers already fit. Blowing them up would spend memory to lose quality.
        let data = try photoData(width: 200, height: 300)
        let downsampled = try XCTUnwrap(ImageDownsampler.image(from: data, maxPixelSize: 1024))
        XCTAssertLessThanOrEqual(max(downsampled.size.width, downsampled.size.height) * downsampled.scale, 300)
    }

    func testUndecodableDataReturnsNil() {
        // The caller treats nil exactly as it treated `UIImage(data:)` returning nil, so this must
        // not start returning a placeholder.
        XCTAssertNil(ImageDownsampler.image(from: Data([0x00, 0x01, 0x02, 0x03])))
    }

    #endif
}
