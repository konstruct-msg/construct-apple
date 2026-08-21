//
//  TranscriptOffsetPolicyTests.swift
//  Construct MessengerTests
//
//  The three offset rules. Each case is one of the two defects the migration measured, or the
//  thing that must not break while fixing them.
//

import XCTest
import CoreGraphics
@testable import Construct_Messenger

final class TranscriptOffsetPolicyTests: XCTestCase {

    private typealias Policy = TranscriptOffsetPolicy

    // Numbers from the stand run of 2026-08-19: 40 messages, iPhone-16-class viewport.
    private let viewport: CGFloat = 700
    private let inset: CGFloat = 90

    // MARK: - Rule 1: landing

    /// The defect this whole decision exists for. `.defaultScrollAnchor(.bottom)` fires on the
    /// first layout, and on that layout the transcript is empty — the store publishes after the
    /// first body pass — so a 40-message chat opened on its oldest message.
    ///
    /// This rule does not care when the content arrived.
    ///
    /// The pass is deliberately **quiet** — the height is the same as last time — so the follow
    /// rule cannot fire and stand in for the landing rule. The first version of this test used
    /// `previousContentHeight: 0`, where both rules return the same offset; deleting the landing
    /// rule outright left it green.
    func testUnprimedContentLandsAtTheBottomWheneverItArrives() {
        let action = Policy.action(
            mode: .following,
            layoutPrimed: false,
            contentHeight: 4000,
            previousContentHeight: 4000,
            viewportHeight: viewport,
            bottomInset: inset,
            currentOffsetY: 0,
            anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 4000 + inset - viewport))
    }

    /// And the growth case still lands, which is what the quiet pass above stops proving.
    func testUnprimedGrowthAlsoLands() {
        XCTAssertEqual(
            Policy.action(
                mode: .following, layoutPrimed: false,
                contentHeight: 4000, previousContentHeight: 0,
                viewportHeight: viewport, bottomInset: inset,
                currentOffsetY: 0, anchorShift: nil
            ),
            .land(offsetY: 4000 + inset - viewport)
        )
    }

    /// It lands from `readingHistory` too. Whatever the geometry said about a transcript that did
    /// not exist yet was not a reading position.
    func testUnprimedLandsEvenIfTheModeSaysHistory() {
        let action = Policy.action(
            mode: .readingHistory,
            layoutPrimed: false,
            contentHeight: 4000,
            previousContentHeight: 0,
            viewportHeight: viewport,
            bottomInset: inset,
            currentOffsetY: 0,
            anchorShift: 120
        )
        XCTAssertEqual(action, .land(offsetY: 4000 + inset - viewport))
    }

    /// Acting on an unmeasured layout is how a 40-message chat read as landed on its first tick.
    func testNothingHappensBeforeAnythingIsMeasured() {
        for (content, port) in [(CGFloat(0), viewport), (4000, 0), (0, 0)] {
            XCTAssertEqual(
                Policy.action(
                    mode: .following, layoutPrimed: false,
                    contentHeight: content, previousContentHeight: 0,
                    viewportHeight: port, bottomInset: inset,
                    currentOffsetY: 0, anchorShift: nil
                ),
                .none,
                "content=\(content) viewport=\(port)"
            )
        }
    }

    /// A transcript shorter than the viewport has no scrollable range; the offset must not go
    /// negative and drag the content off the top.
    func testAShortTranscriptLandsAtZeroRatherThanAboveIt() {
        let action = Policy.action(
            mode: .following, layoutPrimed: false,
            contentHeight: 300, previousContentHeight: 0,
            viewportHeight: viewport, bottomInset: 0,
            currentOffsetY: 0, anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 0))
    }

    // MARK: - Rule 2: following

    /// Growth while following moves the bottom, so the offset moves with it. This is what the
    /// anchor used to be responsible for, and it is the reason `.follow` needs no `scrollTo`.
    func testGrowthWhileFollowingKeepsTheBottom() {
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 4200, previousContentHeight: 4000,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 3390, anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 4200 + inset - viewport))
    }

    /// An unchanged height is not an event. Acting on every layout pass is how the old path
    /// re-pinned 631 times in one session.
    func testAQuietLayoutPassDoesNothing() {
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 4000, previousContentHeight: 4000,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 3390, anchorShift: nil
        )
        XCTAssertEqual(action, .none)
    }

    /// An FRC drop shortens the transcript; following still means the newest is visible.
    func testShrinkingWhileFollowingStillTracksTheBottom() {
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 3000, previousContentHeight: 4000,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 3390, anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 3000 + inset - viewport))
    }

    // MARK: - Rule 3: holding the reader

    /// The prepend the PR-0 spike measured: 20 rows inserted above a bound row moved it 2859pt,
    /// and `.scrollPosition(id:)` compensated for none of it. Adding the same distance to the
    /// offset is the whole fix, and it is one line of arithmetic SwiftUI does not expose.
    func testPrependHoldsTheReaderExactly() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 6891, previousContentHeight: 4032,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 2560, anchorShift: 2859
        )
        XCTAssertEqual(action, .hold(offsetY: 2560 + 2859))
    }

    /// The case no variant covered: a photo above the reader finishes decoding and its row grows.
    /// Same event as a prepend as far as the reader is concerned, and the anchor sees both — which
    /// is why the rule is written on the anchor and not on the content height.
    func testMediaGrowingAboveTheReaderHoldsThemToo() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 4380, previousContentHeight: 4032,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 2560, anchorShift: 348
        )
        XCTAssertEqual(action, .hold(offsetY: 2908))
    }

    /// Growth *below* the reader leaves the anchor where it is, and must leave the offset alone.
    /// Content height alone cannot tell this apart from the case above — both are "it grew".
    func testGrowthBelowTheReaderDoesNotMoveThem() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 4380, previousContentHeight: 4032,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 2560, anchorShift: 0
        )
        XCTAssertEqual(action, .none)
    }

    /// No held row yet — there is nothing to hold them to, and guessing is what the old recovery
    /// did.
    func testHistoryWithoutAnAnchorDoesNothing() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 6891, previousContentHeight: 4032,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 2560, anchorShift: nil
        )
        XCTAssertEqual(action, .none)
    }

    /// The other end of the same clamp, and the one that was missing. A shift is a *correction*,
    /// so it cannot take the viewport somewhere scrolling could not — past the end of the content.
    ///
    /// Device 2026-08-21: the transcript sat with its last message near the top of the screen and a
    /// screenful of void beneath it, and stayed there. `bottomOffset` cannot produce an offset
    /// beyond the end, so nothing downstream brings one back.
    ///
    /// The shift that got there was not a measurement: `anchorShift` was the difference between a
    /// sample of the row bound during this history visit and a sample of the row bound during the
    /// previous one. `TranscriptAnchorSample` carries the row's identity now, so the coordinator
    /// produces no shift at all across a rebind — but the policy still clamps, because a rule that
    /// can move the offset anywhere should not depend on its caller for the range.
    ///
    /// Mutation: drop the `min(bottom, …)`.
    func testAShiftCannotLandPastTheEndOfTheContent() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 2000, previousContentHeight: 2000,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 1200, anchorShift: 4000
        )
        // bottomOffset = 2000 + 90 − 700 = 1390, and 1200 + 4000 is far beyond it.
        XCTAssertEqual(
            action,
            .hold(offsetY: 1390),
            "the last message at the top of the screen with a void under it is not a scroll position"
        )
    }

    /// Rows removed above the reader shift them the other way; the offset must not go negative.
    func testShrinkingAboveTheReaderClampsAtZero() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 2000, previousContentHeight: 4032,
            viewportHeight: viewport, bottomInset: inset,
            currentOffsetY: 100, anchorShift: -900
        )
        XCTAssertEqual(action, .hold(offsetY: 0))
    }

    // MARK: - The bottom itself

    func testBottomOffsetCountsTheComposerAsScrollableRange() {
        XCTAssertEqual(
            Policy.bottomOffset(contentHeight: 4000, viewportHeight: 700, bottomInset: 90),
            3390
        )
    }

    func testBottomOffsetNeverGoesNegative() {
        XCTAssertEqual(
            Policy.bottomOffset(contentHeight: 200, viewportHeight: 700, bottomInset: 90),
            0
        )
    }
}
