//
//  ZoomPanBoundsTests.swift
//  ConstructMessengerTests
//
//  How far a zoomed photo may be panned (`ZoomPanBounds.swift`). The gestures themselves need a
//  finger; what went wrong without a limit — a photo pushed off the screen and left there — is
//  this arithmetic.
//

import XCTest
@testable import Construct_Messenger

final class ZoomPanBoundsTests: XCTestCase {
    private let screen = CGSize(width: 390, height: 844)

    func testALandscapePhotoFitsTheScreensWidth() {
        let fitted = ZoomPanBounds.fittedSize(of: CGSize(width: 4000, height: 3000), in: screen)
        XCTAssertEqual(fitted.width, 390, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 292.5, accuracy: 0.001)
    }

    /// Zoomed ×2 a landscape photo overhangs sideways but is still shorter than the screen:
    /// it pans sideways to its edge and not at all vertically.
    func testTheLimitIsHalfTheOverhangAndZeroWhereNothingOverhangs() {
        let fitted = CGSize(width: 390, height: 292.5)
        let limit = ZoomPanBounds.limit(fitted: fitted, scale: 2, container: screen)
        XCTAssertEqual(limit.width, 195, accuracy: 0.001)
        XCTAssertEqual(limit.height, 0, accuracy: 0.001)

        let fourTimes = ZoomPanBounds.limit(fitted: fitted, scale: 4, container: screen)
        XCTAssertEqual(fourTimes.height, (292.5 * 4 - 844) / 2, accuracy: 0.001)
        XCTAssertEqual(ZoomPanBounds.limit(fitted: fitted, scale: 1, container: screen), .zero)
    }

    /// The defect itself: a drag far past the edge leaves the photo at its edge, in either direction.
    func testAPhotoDraggedOffTheScreenComesBackToItsEdge() {
        let limit = CGSize(width: 195, height: 0)
        XCTAssertEqual(ZoomPanBounds.clamped(CGSize(width: 900, height: -600), limit: limit), CGSize(width: 195, height: 0))
        XCTAssertEqual(ZoomPanBounds.clamped(CGSize(width: -900, height: 600), limit: limit), CGSize(width: -195, height: 0))
        XCTAssertEqual(ZoomPanBounds.clamped(CGSize(width: 40, height: 0), limit: limit), CGSize(width: 40, height: 0))
    }

    /// Inside the limit the photo follows the finger exactly; past it, less and less, and never
    /// as far as the finger went.
    func testPastTheEdgeTheDragMeetsResistance() {
        let limit = CGSize(width: 195, height: 100)
        let inside = CGSize(width: -120, height: 60)
        XCTAssertEqual(ZoomPanBounds.rubberBanded(inside, limit: limit, container: screen), inside)

        let a = ZoomPanBounds.rubberBanded(CGSize(width: 295, height: 0), limit: limit, container: screen).width
        let b = ZoomPanBounds.rubberBanded(CGSize(width: 395, height: 0), limit: limit, container: screen).width
        XCTAssertGreaterThan(a, 195)
        XCTAssertLessThan(a, 295)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b - a, a - 195, "each further point of drag moves the photo less")

        let left = ZoomPanBounds.rubberBanded(CGSize(width: -295, height: -300), limit: limit, container: screen)
        XCTAssertEqual(left.width, -a, accuracy: 0.001)
        XCTAssertLessThan(left.height, -100)
        XCTAssertGreaterThan(left.height, -300)
    }
}
