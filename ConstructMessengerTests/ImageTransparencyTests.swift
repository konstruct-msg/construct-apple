//
//  ImageTransparencyTests.swift
//  Construct MessengerTests
//
//  A sticker that arrives on a black rectangle is not a sticker.
//

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Construct_Messenger

#if canImport(UIKit)
final class ImageTransparencyTests: XCTestCase {

    // MARK: - Which container

    /// PNG is lossless, so for a photograph it is several times the JPEG size and buys
    /// nothing — there is no transparency to keep. Alpha is the only thing that pays for it.
    func testAnOpaqueImageStaysJPEG() {
        XCTAssertEqual(
            MediaOptimizer.chooseEncoding(usesAlpha: false, pngBytes: 1_000, budget: 4_000_000),
            .jpeg
        )
    }

    func testATransparentImageThatFitsIsSentAsPNG() {
        XCTAssertEqual(
            MediaOptimizer.chooseEncoding(usesAlpha: true, pngBytes: 900_000, budget: 4_000_000),
            .png
        )
    }

    /// Delivery beats fidelity. A transparent image over budget arrives as JPEG with its
    /// transparency flattened — worse than a sticker, better than a send that fails.
    func testATransparentImageOverBudgetFallsBackRatherThanFailing() {
        XCTAssertEqual(
            MediaOptimizer.chooseEncoding(usesAlpha: true, pngBytes: 9_000_000, budget: 4_000_000),
            .jpeg
        )
    }

    func testTheBudgetIsInclusive() {
        XCTAssertEqual(
            MediaOptimizer.chooseEncoding(usesAlpha: true, pngBytes: 4_000_000, budget: 4_000_000),
            .png
        )
    }

    func testMimeTypesMatchTheContainer() {
        XCTAssertEqual(ImageEncoding.png.mimeType, "image/png")
        XCTAssertEqual(ImageEncoding.jpeg.mimeType, "image/jpeg")
    }

    // MARK: - Does it actually use alpha

    /// The distinction the choice rests on. A screenshot is RGBA with every alpha at 255:
    /// it has the channel and does not use it, and treating "has a channel" as "is
    /// transparent" would push every screenshot onto the lossless path.
    func testAnOpaqueRGBAImageDoesNotCountAsTransparent() {
        let opaque = Self.image(size: CGSize(width: 64, height: 64), opaque: false) { ctx, rect in
            UIColor.systemBlue.setFill()
            ctx.fill(rect)
        }
        XCTAssertFalse(MediaOptimizer.usesAlpha(opaque))
    }

    func testAPartlyTransparentImageCountsAsTransparent() {
        let sticker = Self.image(size: CGSize(width: 64, height: 64), opaque: false) { ctx, rect in
            UIColor.systemPink.setFill()
            // Left half painted, right half left transparent.
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
        }
        XCTAssertTrue(MediaOptimizer.usesAlpha(sticker))
    }

    func testSemiTransparentPaintCountsToo() {
        let veil = Self.image(size: CGSize(width: 64, height: 64), opaque: false) { ctx, rect in
            UIColor.white.withAlphaComponent(0.4).setFill()
            ctx.fill(rect)
        }
        XCTAssertTrue(MediaOptimizer.usesAlpha(veil))
    }

    // MARK: - End to end

    /// The report: transparency does not survive sending. It did not, because every picked
    /// image went through `jpegData`, which has no alpha channel and flattens it to black.
    func testATransparentImageSurvivesOptimisation() throws {
        let sticker = Self.image(size: CGSize(width: 400, height: 400), opaque: false) { ctx, rect in
            UIColor.systemGreen.setFill()
            ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 40, dy: 40))
        }

        let optimised = try MediaOptimizer.optimizeImage(sticker)

        XCTAssertEqual(optimised.metadata.mimeType, "image/png")
        let decoded = try XCTUnwrap(UIImage(data: optimised.data))
        XCTAssertTrue(
            MediaOptimizer.usesAlpha(decoded),
            "the corner outside the circle came back opaque — transparency was flattened"
        )
    }

    /// The other half of the same rule: a photograph must not be promoted to PNG just
    /// because this path learned about alpha.
    func testAPhotographIsStillSentAsJPEG() throws {
        let photo = Self.image(size: CGSize(width: 400, height: 400), opaque: true) { ctx, rect in
            UIColor.brown.setFill()
            ctx.fill(rect)
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height / 3))
        }
        let optimised = try MediaOptimizer.optimizeImage(photo)
        XCTAssertEqual(optimised.metadata.mimeType, "image/jpeg")
    }

    // MARK: - Helper

    private static func image(
        size: CGSize,
        opaque: Bool,
        draw: (UIGraphicsImageRendererContext, CGRect) -> Void
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(ctx, CGRect(origin: .zero, size: size))
        }
    }
}
#endif
