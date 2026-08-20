//
//  BackSwipeZoneTests.swift
//  ConstructMessengerTests
//
//  Reaching the screen's leading edge one-handed is the far corner from the thumb on a large
//  phone, so the back swipe now starts anywhere in the leading half. That is only safe because
//  swipe-to-reply moved left: while both travelled right they shared a 44pt truce strip, and a
//  half-screen back zone would have swallowed the reply gesture entirely.
//

import XCTest
#if os(iOS)
@testable import Construct_Messenger

final class BackSwipeZoneTests: XCTestCase {

    private let width: CGFloat = 430   // iPhone 17 Pro Max points

    private func canBegin(_ x: CGFloat, canPop: Bool = true, horizontalScroll: Bool = false) -> Bool {
        BackSwipeZone.canBegin(
            startX: x, viewWidth: width, canPop: canPop, insideHorizontalScroll: horizontalScroll
        )
    }

    // MARK: - Where it may start

    func testAnywhereInTheLeadingHalfBegins() {
        XCTAssertTrue(canBegin(2), "the edge still works — the system recognizer owns it, this is the backstop")
        XCTAssertTrue(canBegin(100))
        XCTAssertTrue(canBegin(width / 2 - 1), "the point of the change: mid-screen is reachable one-handed")
    }

    func testTheTrailingHalfDoesNotBegin() {
        XCTAssertFalse(canBegin(width / 2))
        XCTAssertFalse(canBegin(width - 10))
    }

    func testRootScreenNeverBegins() {
        // Swiping back at the root is the classic frozen-navigation bug.
        XCTAssertFalse(canBegin(100, canPop: false))
    }

    func testAHorizontalScrollViewKeepsItsOwnDrag() {
        // Media strips and carousels pan horizontally in the same half of the screen.
        XCTAssertFalse(canBegin(100, horizontalScroll: true))
    }

    // MARK: - Direction — the whole reason a half-screen zone is safe

    func testLeftwardDragIsNeverABackSwipe() {
        // It is a reply. If this ever passes, the two gestures are competing again.
        XCTAssertFalse(BackSwipeZone.isBackDirection(translation: CGPoint(x: -120, y: 0)))
    }

    func testVerticalScrollIsNotABackSwipe() {
        XCTAssertFalse(BackSwipeZone.isBackDirection(translation: CGPoint(x: 10, y: 300)))
        XCTAssertFalse(BackSwipeZone.isBackDirection(translation: CGPoint(x: 100, y: 90)),
                       "a lazy diagonal is a scroll, not a back swipe")
    }

    func testClearlyRightwardDragIsABackSwipe() {
        XCTAssertTrue(BackSwipeZone.isBackDirection(translation: CGPoint(x: 100, y: 20)))
    }

    // MARK: - What commits

    func testDeliberateTravelCommits() {
        XCTAssertTrue(BackSwipeZone.shouldCommit(
            translation: CGPoint(x: BackSwipeZone.commitTranslation, y: 0), velocity: .zero
        ))
    }

    func testFastFlickCommitsWithoutTheFullTravel() {
        XCTAssertTrue(BackSwipeZone.shouldCommit(
            translation: CGPoint(x: 30, y: 0),
            velocity: CGPoint(x: BackSwipeZone.commitVelocity, y: 0)
        ))
    }

    func testAShortSlowDragDoesNotCommit() {
        // Brushing the screen while reading must not leave the chat.
        XCTAssertFalse(BackSwipeZone.shouldCommit(translation: CGPoint(x: 20, y: 0), velocity: .zero))
    }

    func testAFastLeftwardFlickNeverCommits() {
        // Velocity alone must not override direction — that flick is a reply.
        XCTAssertFalse(BackSwipeZone.shouldCommit(
            translation: CGPoint(x: -120, y: 0), velocity: CGPoint(x: -2000, y: 0)
        ))
    }

    func testAFastVerticalFlickNeverCommits() {
        XCTAssertFalse(BackSwipeZone.shouldCommit(
            translation: CGPoint(x: 10, y: 400), velocity: CGPoint(x: 600, y: 3000)
        ))
    }
}
#endif
