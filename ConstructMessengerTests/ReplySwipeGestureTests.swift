import XCTest
import SwiftUI
@testable import Construct_Messenger

/// Swipe-to-reply competes head-on with the interactive back gesture: both are rightward,
/// and incoming bubbles sit against the leading edge where the system pop lives. The
/// original rules were "started anywhere" plus `h > v`, so a swipe meant to leave the chat
/// landed on whatever bubble it began over and quoted it instead.
@MainActor
final class ReplySwipeGestureTests: XCTestCase {
    private typealias Swipe = MessageBubbleRegularView
    private let edge = ChatUIConstants.ReplySwipe.leadingEdgeExclusion
    private let commit = ChatUIConstants.ReplySwipe.commitOffset

    private func offset(startX: CGFloat, dx: CGFloat, dy: CGFloat = 0) -> CGFloat? {
        Swipe.replySwipeOffset(startX: startX, translation: CGSize(width: dx, height: dy))
    }

    // MARK: - The back gesture's strip

    func testDragFromTheScreenEdgeNeverReplies() {
        // A textbook back swipe: starts on the edge, travels far enough to commit.
        XCTAssertNil(offset(startX: 2, dx: 200), "The leading edge belongs to the pop gesture")
        XCTAssertNil(offset(startX: edge, dx: 200), "Exclusion is inclusive of the boundary")
    }

    func testDragJustInboardOfTheStripStillReplies() {
        XCTAssertNotNil(offset(startX: edge + 1, dx: 200))
    }

    /// The strip has to be wider than the system's ~20pt edge zone, otherwise a back swipe
    /// that starts a little inboard falls between the two gestures and does neither.
    func testExclusionIsWiderThanTheSystemEdgeZone() {
        XCTAssertGreaterThan(edge, 30)
    }

    // MARK: - Direction

    func testDiagonalDragDoesNotArm() {
        // 100 across, 90 down — the old `h > v` test passed this, which is why brushing a
        // bubble mid-scroll produced a reply.
        XCTAssertNil(offset(startX: 200, dx: 100, dy: 90))
        XCTAssertNil(offset(startX: 200, dx: 100, dy: -90), "Direction is symmetric in y")
    }

    func testClearlyHorizontalDragArms() {
        XCTAssertNotNil(offset(startX: 200, dx: 100, dy: 20))
    }

    func testLeftwardDragNeverArms() {
        XCTAssertNil(offset(startX: 200, dx: -200))
    }

    func testVerticalScrollNeverArms() {
        XCTAssertNil(offset(startX: 200, dx: 4, dy: 300))
    }

    // MARK: - Travel

    func testBubbleTrailsTheFingerAtHalfSpeedAndIsCapped() {
        XCTAssertEqual(offset(startX: 200, dx: 40), 20)
        XCTAssertEqual(offset(startX: 200, dx: 1000), ChatUIConstants.ReplySwipe.maxOffset)
    }

    /// Committing must take a deliberate distance — the gesture fires on release, so a
    /// short flick should not be enough.
    func testShortFlickDoesNotReachTheCommitThreshold() {
        let short = offset(startX: 200, dx: 50)
        XCTAssertNotNil(short)
        XCTAssertLessThan(short!, commit)

        let deliberate = offset(startX: 200, dx: 80)
        XCTAssertGreaterThanOrEqual(deliberate!, commit)
    }
}
