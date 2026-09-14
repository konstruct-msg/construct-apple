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
            previousViewportHeight: viewport,
            bottomInset: inset,
            previousBottomInset: inset,
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
                viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            previousViewportHeight: viewport,
            bottomInset: inset,
            previousBottomInset: inset,
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
                    viewportHeight: port, previousViewportHeight: port,
                    bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
            bottomInset: 0, previousBottomInset: 0,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
            currentOffsetY: 3390, anchorShift: nil
        )
        XCTAssertEqual(action, .none)
    }

    /// An FRC drop shortens the transcript; following still means the newest is visible.
    func testShrinkingWhileFollowingStillTracksTheBottom() {
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 3000, previousContentHeight: 4000,
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
            currentOffsetY: 3390, anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 3000 + inset - viewport))
    }

    // MARK: - Rule 2, the other two ways the bottom moves (build 630, 2026-08-22)

    /// The keyboard. It shrinks the viewport and touches nothing else, so a rule watching the
    /// content for growth had no event to act on: the follower kept an offset computed for the tall
    /// screen and the keyboard came up over the last messages. Reported from device as "клавиатура
    /// не отодвигает чат, а перекрывает его, приходится отматывать вручную".
    ///
    /// Mutation: drop the `viewportHeight != previousViewportHeight` term.
    func testTheKeyboardMovesAFollowerToTheNewBottom() {
        let keyboard: CGFloat = 336
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 4000, previousContentHeight: 4000,
            viewportHeight: viewport - keyboard, previousViewportHeight: viewport,
            bottomInset: inset, previousBottomInset: inset,
            currentOffsetY: 4000 + inset - viewport,
            anchorShift: nil
        )
        XCTAssertEqual(
            action,
            .land(offsetY: 4000 + inset - (viewport - keyboard)),
            "the content did not change and that was the whole problem — what moved was the screen"
        )
    }

    /// And back down when it goes away: the viewport growing is the same event in the other
    /// direction, and leaving the offset where the small screen put it strands the follower above
    /// the tail with empty space below it.
    func testDismissingTheKeyboardTakesAFollowerBackToTheBottom() {
        let keyboard: CGFloat = 336
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 4000, previousContentHeight: 4000,
            viewportHeight: viewport, previousViewportHeight: viewport - keyboard,
            bottomInset: inset, previousBottomInset: inset,
            currentOffsetY: 4000 + inset - (viewport - keyboard),
            anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 4000 + inset - viewport))
    }

    /// The composer growing a line moves the bottom through the inset rather than the viewport —
    /// the third input, and the one the owned path owns outright.
    ///
    /// Mutation: drop the `bottomInset != previousBottomInset` term.
    func testAGrowingComposerMovesAFollowerToo() {
        let action = Policy.action(
            mode: .following, layoutPrimed: true,
            contentHeight: 4000, previousContentHeight: 4000,
            viewportHeight: viewport, previousViewportHeight: viewport,
            bottomInset: inset + 24, previousBottomInset: inset,
            currentOffsetY: 4000 + inset - viewport,
            anchorShift: nil
        )
        XCTAssertEqual(action, .land(offsetY: 4000 + inset + 24 - viewport))
    }

    /// A reader in history is not dragged to the tail by any of the three. The keyboard coming up
    /// while someone is reading older messages must not end that — rule 3 owns them, and its only
    /// input is the anchor.
    ///
    /// Mutation: move the three-way `moved` test above the `switch` on mode.
    func testTheKeyboardDoesNotDragAReaderOfHistoryToTheTail() {
        let keyboard: CGFloat = 336
        XCTAssertEqual(
            Policy.action(
                mode: .readingHistory, layoutPrimed: true,
                contentHeight: 4000, previousContentHeight: 4000,
                viewportHeight: viewport - keyboard, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
                currentOffsetY: 800, anchorShift: nil
            ),
            .none,
            "tapping the composer is not a request to leave the message you were reading"
        )
    }

    /// All three quiet is still a quiet pass. Without this the new terms could be satisfied by any
    /// layout tick and rule 2 would fire on every one of them.
    func testAQuietPassStaysQuietWithAllThreeInputs() {
        XCTAssertEqual(
            Policy.action(
                mode: .following, layoutPrimed: true,
                contentHeight: 4000, previousContentHeight: 4000,
                viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
                currentOffsetY: 3390, anchorShift: nil
            ),
            .none
        )
    }

    // MARK: - Rule 3: holding the reader

    /// The prepend the PR-0 spike measured: 20 rows inserted above a bound row moved it 2859pt,
    /// and `.scrollPosition(id:)` compensated for none of it. Adding the same distance to the
    /// offset is the whole fix, and it is one line of arithmetic SwiftUI does not expose.
    func testPrependHoldsTheReaderExactly() {
        let action = Policy.action(
            mode: .readingHistory, layoutPrimed: true,
            contentHeight: 6891, previousContentHeight: 4032,
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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
            viewportHeight: viewport, previousViewportHeight: viewport,
                bottomInset: inset, previousBottomInset: inset,
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

    // MARK: - Rule 4: going to one row

    /// Centring places the row in the middle of what the reader can see, which is the viewport
    /// **minus the composer**. Visible height 610, row 100 tall ⇒ 255pt of gap above it.
    ///
    /// Mutation: use `viewportHeight` instead of `viewportHeight - bottomInset`. That is the same
    /// jump, 45pt low — behind the glass by exactly half the composer.
    func testCentringUsesTheAreaTheComposerDoesNotCover() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 2000, rowHeight: 100, anchor: 0.5,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            1745
        )
    }

    /// Anchor 0 is "put this row at the top", so the offset is the row's own position and nothing
    /// else. The simplest case, and the one that says the arithmetic has no stray term in it.
    ///
    /// Mutation: drop the `anchor` factor — the centred case would still pass on a 0.5 default.
    func testTopAnchorPutsTheRowAtTheTop() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 2000, rowHeight: 100, anchor: 0,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            2000
        )
    }

    /// Anchor 1 puts the row's bottom on the bottom edge of the visible area.
    func testBottomAnchorPutsTheRowAtTheBottom() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 2000, rowHeight: 100, anchor: 1,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            1490
        )
    }

    /// The same bound `.hold` was missing until device 2026-08-21: an offset past the end of the
    /// content is not a place scrolling could reach, and nothing downstream brings it back. Jumping
    /// to the newest message in a chat asks for exactly that — centring the last row wants to scroll
    /// past the end.
    ///
    /// Mutation: drop `min(bottom, …)`. The viewport ends up beyond the content with a screenful of
    /// void below it, which is what that device reported.
    func testAJumpToTheNewestRowStopsAtTheEnd() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 3900, rowHeight: 100, anchor: 0.5,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            Policy.bottomOffset(contentHeight: 4000, viewportHeight: viewport, bottomInset: inset)
        )
    }

    /// And the lower bound: centring the first row wants a negative offset.
    ///
    /// Mutation: drop `max(0, …)`.
    func testAJumpToTheOldestRowStopsAtZero() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 0, rowHeight: 100, anchor: 0.5,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            0
        )
    }

    /// A row taller than the screen has no centre that fits, and the answer is still a real offset
    /// rather than a clamp artefact: the middle of the row lands in the middle of the view.
    func testARowTallerThanTheScreenShowsItsMiddle() {
        XCTAssertEqual(
            Policy.rowOffset(
                rowMinY: 1000, rowHeight: 900, anchor: 0.5,
                contentHeight: 4000, viewportHeight: viewport, bottomInset: inset
            ),
            1145
        )
    }
}
