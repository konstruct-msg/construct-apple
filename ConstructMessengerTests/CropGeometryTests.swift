//
//  CropGeometryTests.swift
//  Construct MessengerTests
//
//  The crop editor's arithmetic, without the gestures.
//

import XCTest
import CoreGraphics
@testable import Construct_Messenger

final class CropGeometryTests: XCTestCase {

    private let container = CGSize(width: 300, height: 300)

    // MARK: - The window

    /// Free follows the picture, so opening the editor and pressing Done returns it
    /// unchanged. An editor that quietly squares every photo is worse than no editor.
    func testFreeWindowTakesTheImagesOwnShape() {
        let landscape = CropGeometry.cropWindow(container: container, aspect: .free, imageAspect: 2)
        XCTAssertEqual(landscape.width / landscape.height, 2, accuracy: 0.001)

        let portrait = CropGeometry.cropWindow(container: container, aspect: .free, imageAspect: 0.5)
        XCTAssertEqual(portrait.width / portrait.height, 0.5, accuracy: 0.001)
    }

    func testFixedAspectsIgnoreTheImageShape() {
        for aspect in [CropAspect.square, .fourThree, .sixteenNine] {
            let window = CropGeometry.cropWindow(container: container, aspect: aspect, imageAspect: 3.7)
            XCTAssertEqual(window.width / window.height, aspect.ratio!, accuracy: 0.001,
                           "\(aspect.label) did not hold its ratio")
        }
    }

    /// The window is the largest of its shape that fits — letterboxed on whichever axis
    /// runs out first, never spilling past the container.
    func testTheWindowFitsTheContainer() {
        for aspect in CropAspect.allCases {
            let window = CropGeometry.cropWindow(container: container, aspect: aspect, imageAspect: 1.6)
            XCTAssertLessThanOrEqual(window.width, container.width + 0.001, "\(aspect.label) too wide")
            XCTAssertLessThanOrEqual(window.height, container.height + 0.001, "\(aspect.label) too tall")
            XCTAssertTrue(
                abs(window.width - container.width) < 0.001 || abs(window.height - container.height) < 0.001,
                "\(aspect.label) touches neither edge — it is not the largest that fits"
            )
        }
    }

    func testADegenerateContainerDoesNotProduceNaN() {
        let window = CropGeometry.cropWindow(container: .zero, aspect: .square, imageAspect: 1)
        XCTAssertEqual(window, .zero)
    }

    // MARK: - Zoom floor

    /// Below the covering scale the window would show empty space, and a crop containing
    /// nothing is not a picture anyone chose.
    func testMinimumScaleCoversTheWindow() {
        let displayed = CGSize(width: 300, height: 150)
        let window = CGSize(width: 300, height: 300)
        let min = CropGeometry.minimumScale(displayedImageSize: displayed, window: window)

        XCTAssertGreaterThanOrEqual(displayed.width * min, window.width - 0.001)
        XCTAssertGreaterThanOrEqual(displayed.height * min, window.height - 0.001)
    }

    // MARK: - Panning

    func testAnImageThatExactlyFillsTheWindowCannotBeDragged() {
        let limit = CropGeometry.offsetLimit(
            displayedImageSize: CGSize(width: 300, height: 300),
            scale: 1,
            window: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(limit.width, 0)
        XCTAssertEqual(limit.height, 0)
    }

    func testPanningStopsBeforeAnEdgeEntersTheWindow() {
        let displayed = CGSize(width: 400, height: 300)
        let window = CGSize(width: 300, height: 300)
        let clamped = CropGeometry.clampedOffset(
            CGSize(width: 9_999, height: 9_999),
            displayedImageSize: displayed, scale: 1, window: window
        )
        XCTAssertEqual(clamped.width, 50, accuracy: 0.001)
        XCTAssertEqual(clamped.height, 0, accuracy: 0.001)
    }

    // MARK: - The rect that is actually cut

    /// Untouched gestures on a free window means "keep everything".
    func testAnUntouchedFreeCropKeepsTheWholeImage() {
        let pixels = CGSize(width: 1_600, height: 900)
        let window = CropGeometry.cropWindow(container: container, aspect: .free, imageAspect: 16.0 / 9.0)
        let rect = CropGeometry.cropRect(
            imagePixelSize: pixels,
            displayedImageSize: window,
            scale: 1,
            offset: .zero,
            window: window
        )
        XCTAssertEqual(rect.origin.x, 0, accuracy: 1)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 1)
        XCTAssertEqual(rect.width, pixels.width, accuracy: 1)
        XCTAssertEqual(rect.height, pixels.height, accuracy: 1)
    }

    /// A square window over a landscape picture keeps a centred square of full height.
    func testASquareWindowOverALandscapeImageTakesTheCentre() {
        let pixels = CGSize(width: 1_600, height: 900)
        let window = CGSize(width: 300, height: 300)
        let displayed = CGSize(width: 300 * 16.0 / 9.0, height: 300)

        let rect = CropGeometry.cropRect(
            imagePixelSize: pixels,
            displayedImageSize: displayed,
            scale: 1,
            offset: .zero,
            window: window
        )
        XCTAssertEqual(rect.width, 900, accuracy: 2, "a square of full height")
        XCTAssertEqual(rect.height, 900, accuracy: 2)
        XCTAssertEqual(rect.midX, pixels.width / 2, accuracy: 2, "not centred")
    }

    /// Zoom must reduce what is kept, or the pinch is decorative.
    func testZoomingInKeepsLess() {
        let pixels = CGSize(width: 1_000, height: 1_000)
        let window = CGSize(width: 300, height: 300)
        let displayed = CGSize(width: 300, height: 300)

        let wide = CropGeometry.cropRect(imagePixelSize: pixels, displayedImageSize: displayed,
                                         scale: 1, offset: .zero, window: window)
        let close = CropGeometry.cropRect(imagePixelSize: pixels, displayedImageSize: displayed,
                                          scale: 2, offset: .zero, window: window)
        XCTAssertLessThan(close.width, wide.width)
        XCTAssertEqual(close.width, wide.width / 2, accuracy: 2)
    }

    /// `CGImage.cropping(to:)` returns nil for a rect outside the image, and a nil there
    /// means the editor hands back the uncropped original while claiming it cropped.
    func testTheRectNeverLeavesTheImage() {
        let pixels = CGSize(width: 800, height: 600)
        let window = CGSize(width: 300, height: 300)
        for offset in [CGSize(width: 10_000, height: 0), CGSize(width: -10_000, height: -10_000)] {
            let rect = CropGeometry.cropRect(
                imagePixelSize: pixels,
                displayedImageSize: CGSize(width: 400, height: 300),
                scale: 1, offset: offset, window: window
            )
            XCTAssertTrue(
                CGRect(origin: .zero, size: pixels).contains(rect),
                "rect \(rect) escaped the image for offset \(offset)"
            )
        }
    }

    func testADegenerateScaleFallsBackToTheWholeImage() {
        let pixels = CGSize(width: 800, height: 600)
        let rect = CropGeometry.cropRect(
            imagePixelSize: pixels,
            displayedImageSize: CGSize(width: 400, height: 300),
            scale: 0, offset: .zero, window: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(rect, CGRect(origin: .zero, size: pixels))
    }

    // MARK: - Orientation

    func testFourQuarterTurnsComeBackToTheStart() {
        var o = CropOrientation.identity
        for _ in 0..<4 { o.rotateClockwise() }
        XCTAssertEqual(o, .identity)
        XCTAssertTrue(o.isIdentity)
    }

    func testAQuarterTurnSwapsTheAxes() {
        var o = CropOrientation.identity
        o.rotateClockwise()
        XCTAssertTrue(o.swapsAxes)
        XCTAssertEqual(o.apply(to: CGSize(width: 100, height: 40)), CGSize(width: 40, height: 100))
    }

    func testAHalfTurnKeepsTheAxes() {
        var o = CropOrientation.identity
        o.rotateClockwise(); o.rotateClockwise()
        XCTAssertFalse(o.swapsAxes)
        XCTAssertEqual(o.apply(to: CGSize(width: 100, height: 40)), CGSize(width: 100, height: 40))
    }

    func testMirroringTwiceIsNoMirror() {
        var o = CropOrientation.identity
        o.mirror(); o.mirror()
        XCTAssertTrue(o.isIdentity)
    }

    // MARK: - Doing nothing

    /// Confirming an untouched editor must not re-encode. A JPEG generation for nothing is
    /// the mild cost; on a transparent PNG a needless round trip is the difference between
    /// a sticker and a black rectangle.
    func testAnUntouchedEditIsRecognisedAsANoOp() {
        let pixels = CGSize(width: 1_200, height: 800)
        XCTAssertTrue(CropGeometry.isNoOp(
            cropRect: CGRect(origin: .zero, size: pixels),
            imagePixelSize: pixels,
            orientation: .identity
        ))
    }

    func testARotationIsNeverANoOp() {
        let pixels = CGSize(width: 1_200, height: 800)
        var rotated = CropOrientation.identity
        rotated.rotateClockwise()
        XCTAssertFalse(CropGeometry.isNoOp(
            cropRect: CGRect(origin: .zero, size: pixels),
            imagePixelSize: pixels,
            orientation: rotated
        ))
    }

    func testAnActualCropIsNotANoOp() {
        let pixels = CGSize(width: 1_200, height: 800)
        XCTAssertFalse(CropGeometry.isNoOp(
            cropRect: CGRect(x: 100, y: 0, width: 1_100, height: 800),
            imagePixelSize: pixels,
            orientation: .identity
        ))
    }
}
