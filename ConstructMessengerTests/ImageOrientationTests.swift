//
//  ImageOrientationTests.swift
//  Construct MessengerTests
//
//  A photo off a phone camera carries its picture in two spaces at once. These fix which one
//  the editor works in.
//

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Construct_Messenger

#if canImport(UIKit)
final class ImageOrientationTests: XCTestCase {

    // MARK: - The invariant that was violated

    /// The whole defect in one assertion. `size` is display space, `cgImage` is buffer space,
    /// and for a `.right` photo they are a quarter turn apart — so a rect measured against
    /// `size` addresses pixels that are not there.
    func testARotatedPhotoDisagreesWithItsOwnBuffer() {
        let photo = Self.oriented(bufferWidth: 400, bufferHeight: 300, as: .right)

        XCTAssertEqual(photo.size, CGSize(width: 300, height: 400), "display space is turned")
        XCTAssertEqual(photo.cgImage?.width, 400, "buffer space is not")
    }

    func testNormalisingMakesThemAgree() {
        let photo = Self.oriented(bufferWidth: 400, bufferHeight: 300, as: .right)
        let up = photo.normalizedUp()

        XCTAssertEqual(up.imageOrientation, .up)
        XCTAssertEqual(up.size, photo.size, "the picture must look the same size as before")
        XCTAssertEqual(up.cgImage?.width, Int(up.size.width * up.scale))
        XCTAssertEqual(up.cgImage?.height, Int(up.size.height * up.scale))
    }

    /// An image already in one space must not be redrawn: that would cost a generation on
    /// every open, including the no-op Done the editor is careful to avoid.
    func testAnUprightImageIsReturnedUntouched() {
        let plain = Self.solid(size: CGSize(width: 40, height: 40), color: .systemRed)
        XCTAssertTrue(plain.normalizedUp() === plain)
    }

    /// Normalising must not flatten a sticker on the way through.
    func testNormalisingKeepsTransparency() throws {
        let sticker = Self.image(size: CGSize(width: 60, height: 60), opaque: false) { ctx, rect in
            UIColor.systemTeal.setFill()
            ctx.cgContext.fillEllipse(in: rect)
        }
        let buffer = try XCTUnwrap(sticker.cgImage)
        let rotated = UIImage(cgImage: buffer, scale: 1, orientation: .right)
        XCTAssertTrue(MediaOptimizer.usesAlpha(rotated.normalizedUp()), "the corners came back opaque")
    }

    // MARK: - Content, not just dimensions

    /// Dimensions agreeing is not the same as the picture surviving. This one would still pass
    /// if `normalizedUp` returned a correctly-sized blank.
    func testNormalisingPreservesWhatTheViewerSees() {
        // Buffer: left half red, right half blue. Displayed `.right` — a quarter turn
        // clockwise — that red half is at the TOP.
        let buffer = Self.image(size: CGSize(width: 80, height: 40), opaque: true) { ctx, rect in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height))
        }
        let photo = UIImage(cgImage: buffer.cgImage!, scale: 1, orientation: .right)
        let up = photo.normalizedUp()

        XCTAssertEqual(Self.pixel(up, at: CGPoint(x: 20, y: 10)), .red, "top should be the red half")
        XCTAssertEqual(Self.pixel(up, at: CGPoint(x: 20, y: 70)), .blue, "bottom should be the blue half")
    }

    // MARK: - Cropping

    /// The report: rotation saves, cropping does not. It did not, because the rect was cut out
    /// of the un-turned buffer and the result was then declared upright — so what came back was
    /// a different region of a differently-turned picture, which reads on screen as "nothing
    /// was saved".
    func testCroppingARotatedPhotoUsesTheSpaceTheUserSaw() {
        // Three stripes down the buffer, 20 columns each: red, green, then blue over the rest.
        // Displayed `.right`, the buffer's columns become the picture's rows — so the viewer
        // sees red across the top 20 rows, green over the next 20, blue below.
        //
        // The widths are chosen so that a rect read against the buffer and the same rect read
        // against the picture do not coincide. An earlier version of this test used two halves,
        // and both readings landed inside the red one: it passed against the defect.
        let buffer = Self.image(size: CGSize(width: 80, height: 40), opaque: true) { ctx, _ in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        }
        let photo = UIImage(cgImage: buffer.cgImage!, scale: 1, orientation: .right)
        XCTAssertEqual(photo.size, CGSize(width: 40, height: 80))

        // Keep the top stripe, as displayed: the whole width, the first 20 rows.
        let cropped = photo.cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))

        XCTAssertEqual(cropped.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(cropped.imageOrientation, .up)
        // Every pixel of that stripe is red. Cutting the same rect out of the buffer instead
        // returns red beside green, which is what this catches.
        for x in [5, 20, 30, 38] {
            XCTAssertEqual(Self.pixel(cropped, at: CGPoint(x: x, y: 10)), .red,
                           "at x=\(x) the crop came from the buffer, not from the picture")
        }
    }

    /// Pinch to enlarge and let the frame trim the rest — no aspect chosen, just zoom. It runs
    /// through the same cut as a framed crop, so it failed the same way, and this is the shape
    /// the defect was actually reported in.
    ///
    /// Composes the real arithmetic with the real cut rather than asserting on a hand-written
    /// rect: the two agreeing is the thing that was broken.
    func testZoomingIntoARotatedPhotoKeepsTheMiddleOfWhatWasOnScreen() {
        // Buffer 80×40; displayed `.right` that is a 40×80 portrait. The band painted here
        // lands exactly on the middle of the picture as the viewer sees it.
        let buffer = Self.image(size: CGSize(width: 80, height: 40), opaque: true) { ctx, rect in
            UIColor.red.setFill()
            ctx.fill(rect)
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 20, y: 10, width: 40, height: 20))
        }
        let photo = UIImage(cgImage: buffer.cgImage!, scale: 1, orientation: .right)

        // Free aspect: the window takes the picture's own shape, so at rest the whole photo
        // is in frame. Pinch to 2×.
        let window = CGSize(width: 40, height: 80)
        let rect = CropGeometry.cropRect(
            imagePixelSize: photo.size,
            displayedImageSize: window,
            scale: 2,
            offset: .zero,
            window: window
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 20, height: 40), "the middle at 2×")

        let cropped = photo.cropped(to: rect)

        XCTAssertEqual(cropped.size, CGSize(width: 20, height: 40))
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 20), CGPoint(x: 18, y: 38)] {
            XCTAssertEqual(Self.pixel(cropped, at: point), .green,
                           "at \(point) the zoom kept a region the viewer never framed")
        }
    }

    func testCroppingAnUprightImageIsUnaffected() {
        let image = Self.image(size: CGSize(width: 100, height: 100), opaque: true) { ctx, rect in
            UIColor.green.setFill()
            ctx.fill(rect)
            UIColor.magenta.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 25))
        }
        let cropped = image.cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))

        XCTAssertEqual(cropped.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(Self.pixel(cropped, at: CGPoint(x: 50, y: 25)), .green)
    }

    // MARK: - Turns

    /// Rotation always worked, and must keep working now that it runs through the normalised
    /// buffer rather than the raw one.
    func testAQuarterTurnSwapsTheAxes() {
        let photo = Self.oriented(bufferWidth: 400, bufferHeight: 300, as: .right)  // displays 300×400
        var turn = CropOrientation.identity
        turn.rotateClockwise()

        XCTAssertEqual(photo.applying(turn).size, CGSize(width: 400, height: 300))
    }

    func testMirroringKeepsTheShape() {
        let photo = Self.oriented(bufferWidth: 400, bufferHeight: 300, as: .right)
        var turn = CropOrientation.identity
        turn.mirror()

        XCTAssertEqual(photo.applying(turn).size, photo.size)
    }

    // MARK: - Helpers

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

    private static func solid(size: CGSize, color: UIColor) -> UIImage {
        image(size: size, opaque: true) { ctx, rect in
            color.setFill()
            ctx.fill(rect)
        }
    }

    /// A buffer of the given pixel dimensions, tagged with a display orientation — the shape a
    /// photo arrives in from the camera roll.
    private static func oriented(bufferWidth: Int, bufferHeight: Int, as orientation: UIImage.Orientation) -> UIImage {
        let buffer = solid(size: CGSize(width: bufferWidth, height: bufferHeight), color: .systemPink)
        return UIImage(cgImage: buffer.cgImage!, scale: 1, orientation: orientation)
    }

    private enum Sample: Equatable { case red, blue, green, magenta, other }

    /// Which of the test colours sits at a point, in the image's own display space.
    ///
    /// Draws into a bitmap context and indexes it. A bitmap context's memory starts at the top
    /// row, so `y` counts down from the top of the picture — the same direction the assertions
    /// above are written in.
    private static func pixel(_ image: UIImage, at point: CGPoint) -> Sample {
        guard let cg = image.normalizedUp().cgImage else { return .other }
        let width = cg.width, height = cg.height
        // `data: nil` lets CGContext own the buffer, so nothing here outlives its storage.
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .other }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        guard (0..<width).contains(x), (0..<height).contains(y),
              let raw = ctx.data else { return .other }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        let (r, g, b) = (bytes[i], bytes[i + 1], bytes[i + 2])
        let high: (UInt8) -> Bool = { $0 > 180 }
        let low: (UInt8) -> Bool = { $0 < 75 }
        if high(r) && low(g) && low(b) { return .red }
        if low(r) && low(g) && high(b) { return .blue }
        if low(r) && high(g) && low(b) { return .green }
        if high(r) && low(g) && high(b) { return .magenta }
        return .other
    }
}
#endif
