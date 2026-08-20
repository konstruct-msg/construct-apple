import XCTest
import SwiftUI
@testable import Construct_Messenger

/// Swipe-to-reply used to travel **right**, head-on into the interactive back gesture, and the
/// two were told apart by where the drag began: a 44pt leading strip was conceded to the pop.
/// That is a truce, not a separation — one direction serving two roles, arbitrated by a margin.
/// It leaked both ways: a back swipe starting further inboard quoted whatever bubble it began
/// over, and the concession made the leftmost 44pt of every incoming bubble un-swipeable, which
/// is precisely where the short ones sit.
///
/// The reply swipe now travels **left**. No start position can make a leftward drag look like a
/// rightward pop, so the strip is gone and every pixel of every bubble is live.
@MainActor
final class ReplySwipeGestureTests: XCTestCase {
    private typealias Swipe = MessageBubbleRegularView
    private let commit = ChatUIConstants.ReplySwipe.commitOffset

    /// `dx` is signed screen travel; leftward is negative, as SwiftUI reports it.
    private func offset(dx: CGFloat, dy: CGFloat = 0) -> CGFloat? {
        Swipe.replySwipeOffset(translation: CGSize(width: dx, height: dy))
    }

    // MARK: - Direction is the whole separation

    func testRightwardDragNeverArms() {
        // The back gesture's direction. Whatever else it is, it is not a reply — and unlike the
        // old rule, this holds no matter where on the screen it started.
        XCTAssertNil(offset(dx: 200))
        XCTAssertNil(offset(dx: 45))
    }

    func testLeftwardDragArms() {
        XCTAssertNotNil(offset(dx: -200))
    }

    func testABubbleIsSwipeableAlongItsWholeWidth() {
        // The regression the exclusion strip caused: a short incoming bubble near the leading
        // edge could not be replied to at all. Start position is no longer an input, so this is
        // now true by construction — asserted so a future "just add a small guard" has to fail here.
        XCTAssertNotNil(offset(dx: -80), "no start position, no dead zone")
    }

    // MARK: - Direction ratio

    func testDiagonalDragDoesNotArm() {
        // 100 across, 90 down — a plain `h > v` test passes this, which is why brushing a bubble
        // mid-scroll used to produce a reply.
        XCTAssertNil(offset(dx: -100, dy: 90))
        XCTAssertNil(offset(dx: -100, dy: -90), "direction is symmetric in y")
    }

    func testClearlyHorizontalDragArms() {
        XCTAssertNotNil(offset(dx: -100, dy: 20))
    }

    func testVerticalScrollNeverArms() {
        XCTAssertNil(offset(dx: -4, dy: 300))
    }

    // MARK: - Travel

    func testBubbleTrailsTheFingerAtHalfSpeedAndIsCapped() {
        XCTAssertEqual(offset(dx: -40), 20)
        XCTAssertEqual(offset(dx: -1000), ChatUIConstants.ReplySwipe.maxOffset)
    }

    func testOffsetIsAPositiveMagnitude() {
        // The call site applies the sign (`.offset(x: -swipeOffset)`) and the indicator's
        // opacity divides by it. A negative here would invert the bubble and blank the arrow.
        XCTAssertGreaterThan(offset(dx: -100)!, 0)
    }

    /// Committing must take a deliberate distance — the gesture fires on release, so a short
    /// flick should not be enough.
    func testShortFlickDoesNotReachTheCommitThreshold() {
        let short = offset(dx: -50)
        XCTAssertNotNil(short)
        XCTAssertLessThan(short!, commit)

        let deliberate = offset(dx: -80)
        XCTAssertGreaterThanOrEqual(deliberate!, commit)
    }
}
