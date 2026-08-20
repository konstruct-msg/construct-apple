//
//  ChatViewportTests.swift
//  Construct MessengerTests
//
//  PR-3 step 1. The policy, before any view depends on it.
//
//  Every case here is a decision that was wrong in a shipped build, and the build number is in the
//  comment. A test whose numbers came from imagination proves the code agrees with the imagination.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

@MainActor
final class ChatViewportTests: XCTestCase {

    private typealias Viewport = ChatViewport
    private typealias Flags = ChatViewport.ScrollFlags

    // MARK: - Landing

    /// Build 583, the blank chat: content 3952, viewport [3942…4874], so the visible rect runs
    /// 922pt **past** the end of the content and 1 % of it shows transcript.
    ///
    /// `distanceFromBottom <= nearBottom` says yes to this — −922 is very much ≤ 60 — which is how
    /// a viewport parked past the end kept reading as a landed tail.
    func testShouldPrime_build583PastEnd_isFalse() {
        let fraction = Viewport.visibleContentFraction(
            contentHeight: 3952,
            visibleMinY: 3942,
            distanceFromBottom: -922
        )
        XCTAssertLessThan(fraction, 0.05, "the 583 geometry should cover almost nothing")

        XCTAssertFalse(
            Viewport.shouldPrime(
                alreadyPrimed: false,
                messageCount: 50,
                contentHeight: 3952,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: fraction
            ),
            "a viewport past the end of the content is not a landed tail"
        )
    }

    /// The healthy shape of the same measurement: at rest with only the composer inset, a little
    /// negative and almost fully covered.
    func testShouldPrime_atRestUnderTheComposer_isTrue() {
        XCTAssertTrue(
            Viewport.shouldPrime(
                alreadyPrimed: false,
                messageCount: 8,
                contentHeight: 2525,
                distanceFromBottom: -83,
                contentFits: false,
                visibleContentFraction: 0.9
            )
        )
    }

    /// Build 593: eleven messages, 798pt of content against a taller viewport. Coverage is a fill
    /// level here, not a position, and a short chat must still be able to land.
    func testShouldPrime_shortTranscriptLandsOnFitAlone() {
        XCTAssertTrue(
            Viewport.shouldPrime(
                alreadyPrimed: false,
                messageCount: 11,
                contentHeight: 798,
                distanceFromBottom: -538,
                contentFits: true,
                visibleContentFraction: 0.42
            )
        )
    }

    /// Found on the stand, 2026-08-19, on the first live run of the eager path: a 40-message chat
    /// opened on the oldest message and load-more went 30 → 40 before a row existed. `contentFits`
    /// is `contentSize <= viewport`, and an unmeasured stack satisfies that with a height of zero,
    /// so the very first tick read as a landed tail.
    func testShouldPrime_unmeasuredContentDoesNotCountAsFitting() {
        XCTAssertFalse(
            Viewport.shouldPrime(
                alreadyPrimed: false,
                messageCount: 40,
                contentHeight: 0,
                distanceFromBottom: 0,
                contentFits: true,
                visibleContentFraction: 1
            ),
            "nothing is laid out yet — that is not a transcript that fits"
        )
    }

    func testShouldPrime_emptyTranscriptNeverLands() {
        XCTAssertFalse(
            Viewport.shouldPrime(
                alreadyPrimed: false,
                messageCount: 0,
                contentHeight: 0,
                distanceFromBottom: 0,
                contentFits: true,
                visibleContentFraction: 1
            ),
            "no messages is not a landed tail, whatever the geometry says"
        )
    }

    func testShouldPrime_isSticky() {
        XCTAssertTrue(
            Viewport.shouldPrime(
                alreadyPrimed: true,
                messageCount: 50,
                contentHeight: 3952,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: 0.01
            ),
            "media settling after the landing must not un-land it"
        )
    }

    // MARK: - Unprimed geometry is not intent

    /// The core one-way rule. Before the tail lands, a large distance is as likely to be an offset
    /// that has not arrived as a person who scrolled up — and reading it as the person switched
    /// following off, after which every correction refused to run.
    func testUnprimed_farFromBottomDoesNotDisableFollowing() {
        let next = Viewport.flags(
            current: Flags(following: true, showJumpButton: false),
            distanceFromBottom: 2400,
            contentFits: false,
            insetSettling: false,
            layoutPrimed: false
        )
        XCTAssertTrue(next.following, "unprimed geometry may turn following on, never off")
        XCTAssertFalse(next.showJumpButton, "and the FAB must not flash over a list that has not landed")
    }

    /// The other direction of the same rule: it may still turn following back **on**.
    func testUnprimed_nearBottomCanTurnFollowingOn() {
        let next = Viewport.flags(
            current: Flags(following: false, showJumpButton: false),
            distanceFromBottom: 10,
            contentFits: false,
            insetSettling: false,
            layoutPrimed: false
        )
        XCTAssertTrue(next.following)
    }

    /// Once landed, distance is intent again.
    func testPrimed_farFromBottomStopsFollowing() {
        let next = Viewport.flags(
            current: Flags(following: true, showJumpButton: false),
            distanceFromBottom: 2400,
            contentFits: false,
            insetSettling: false,
            layoutPrimed: true
        )
        XCTAssertFalse(next.following)
        XCTAssertTrue(next.showJumpButton)
    }

    /// Build 588 entered this by the other door: a keyboard that was never dismissed left the
    /// flags latched, and 128 messages of reading were animated back to the newest message.
    /// The latch is right; what it must not do is decide on its own.
    func testPadOrKeyboardAnimating_farUpLeavesModeUnchanged() {
        let reading = Viewport.flags(
            current: Flags(following: false, showJumpButton: true),
            distanceFromBottom: 2378,
            contentFits: false,
            insetSettling: true,
            layoutPrimed: true
        )
        XCTAssertFalse(reading.following, "an inset in motion must not drag a reader to the tail")

        let following = Viewport.flags(
            current: Flags(following: true, showJumpButton: false),
            distanceFromBottom: 2378,
            contentFits: false,
            insetSettling: true,
            layoutPrimed: true
        )
        XCTAssertTrue(following.following, "nor switch following off on a transient distance")
    }

    func testContentFitsAlwaysFollowsAndHidesTheJumpButton() {
        let next = Viewport.flags(
            current: Flags(following: false, showJumpButton: true),
            distanceFromBottom: -538,
            contentFits: true,
            insetSettling: false,
            layoutPrimed: true
        )
        XCTAssertTrue(next.following)
        XCTAssertFalse(next.showJumpButton, "nothing to jump to when the transcript fits")
    }

    // MARK: - The inset latch

    /// The fixture that matters: safe area and container move, composer height does not. A latch
    /// wired only to the composer reads this as a settled layout — which is the keyboard case.
    func testInsetLatch_seesSafeAreaWithoutComposerChange() {
        let viewport = Viewport()
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        XCTAssertFalse(viewport.insetSettling, "the first report is a baseline, not a move")

        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 0, containerHeight: 700)
        XCTAssertTrue(viewport.insetSettling, "the bottom safe area collapsed by 34pt")
    }

    func testInsetLatch_seesContainerHeightWithoutComposerChange() {
        let viewport = Viewport()
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 420)
        XCTAssertTrue(viewport.insetSettling)
    }

    func testInsetLatch_clearsOnTheNextQuietTick() {
        let viewport = Viewport()
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 34, containerHeight: 700)
        XCTAssertTrue(viewport.insetSettling)

        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 34, containerHeight: 700)
        XCTAssertFalse(viewport.insetSettling, "no timer — the next quiet measurement clears it")
    }

    /// Sub-threshold movement is layout noise. Latching on it would leave the chat permanently
    /// "settling", which reads as "geometry is never intent" — the opening timer by another name.
    func testInsetLatch_ignoresNoise() {
        let viewport = Viewport()
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        viewport.noteInsetDelta(composer: 94, safeAreaBottom: 36, containerHeight: 703)
        XCTAssertFalse(viewport.insetSettling)
    }

    // MARK: - Load-more

    /// TODO 34: an eager sentinel is in the tree from the first frame, and on a cold entry the
    /// content legitimately "fits" before anything has landed. Both readings said yes, and every
    /// chat entry widened 30 → 50 unasked.
    func testUnprimed_refusesLoadOlderEvenAtTop() {
        XCTAssertFalse(
            Viewport.shouldLoadOlderHistory(
                layoutPrimed: false,
                contentFits: false,
                visibleMinY: 0,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            ),
            "viewportMinY 0 before landing means nobody has looked, not that we are at the top"
        )
    }

    func testUnprimed_refusesLoadOlderEvenWhenContentFits() {
        XCTAssertFalse(
            Viewport.shouldLoadOlderHistory(
                layoutPrimed: false,
                contentFits: true,
                visibleMinY: 400,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    func testPrimedAtTheOldestEdgeLoadsMore() {
        XCTAssertTrue(
            Viewport.shouldLoadOlderHistory(
                layoutPrimed: true,
                contentFits: false,
                visibleMinY: 12,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    func testPrimedButMidTranscriptDoesNotLoadMore() {
        XCTAssertFalse(
            Viewport.shouldLoadOlderHistory(
                layoutPrimed: true,
                contentFits: false,
                visibleMinY: 2560,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    func testSearchAndInFlightLoadsAreRefused() {
        for (search, loading, more) in [(true, false, true), (false, true, true), (false, false, false)] {
            XCTAssertFalse(
                Viewport.shouldLoadOlderHistory(
                    layoutPrimed: true,
                    contentFits: true,
                    visibleMinY: 0,
                    isSearchActive: search,
                    isLoadingMore: loading,
                    hasMoreMessages: more
                ),
                "search=\(search) loading=\(loading) more=\(more)"
            )
        }
    }

    // MARK: - Count changes

    func testZeroToNOpensTheTranscriptWhateverTheModeWas() {
        XCTAssertEqual(
            Viewport.countChangeAction(
                oldCount: 0, newCount: 30,
                mode: .readingHistory,
                searchActive: false,
                incomingFollowSuppressed: false
            ),
            .openTranscript,
            "whatever geometry said about a blank list was not a reading position"
        )
    }

    /// An append while following is `.follow`, and `.follow` must not scroll: the anchor holds the
    /// tail on its own — measured in the PR-0 spike, where growing the pad at the bottom left
    /// `distanceFromBottom` at 0 with no `scrollTo` at all.
    /// What this can and cannot prove: `ScrollViewProxy` has no initialiser reachable from a test,
    /// so "no `scrollTo` was issued" is not observable here. It is held by the reviewer invariant
    /// instead — no `proxy.scrollTo` outside `ChatViewport` — and what is asserted is the part that
    /// can fail: an append while following changes no state whatsoever. Adding a follow-scroll back
    /// would mean touching `positionId` or `mode` to do it, and that reddens.
    func testCountGrowth_whileFollowing_doesNotScrollTo() {
        XCTAssertEqual(
            Viewport.countChangeAction(
                oldCount: 30, newCount: 31,
                mode: .following,
                searchActive: false,
                incomingFollowSuppressed: false
            ),
            .follow
        )

        let viewport = Viewport()
        viewport.handleTranscriptCountChange(oldCount: 30, newCount: 31, searchActive: false)
        XCTAssertEqual(viewport.mode, .following)
        XCTAssertNil(viewport.positionId)
        XCTAssertFalse(viewport.showJumpButton)
        XCTAssertFalse(viewport.layoutPrimed, "an append is not a landing")
    }

    /// An FRC drop shortens the transcript. Following that would scroll on a deletion.
    func testShrinkingTranscriptIsNotAFollow() {
        XCTAssertEqual(
            Viewport.countChangeAction(
                oldCount: 50, newCount: 30,
                mode: .following,
                searchActive: false,
                incomingFollowSuppressed: false
            ),
            .none
        )
    }

    func testGrowthWhileReadingHistoryIsIgnored() {
        XCTAssertEqual(
            Viewport.countChangeAction(
                oldCount: 30, newCount: 31,
                mode: .readingHistory,
                searchActive: false,
                incomingFollowSuppressed: false
            ),
            .none
        )
    }

    // MARK: - Guests never assign mode

    /// Reply peek holds a parent on screen. It suppresses the follow and leaves the mode alone —
    /// the person has not started reading history, and pretending they have would strand them
    /// there when the peek ends.
    func testPeek_doesNotAssignMode() {
        let viewport = Viewport()
        XCTAssertEqual(viewport.mode, .following)

        viewport.setIncomingFollowSuppressed(true)

        XCTAssertEqual(viewport.mode, .following, "peek is not a reading position")
        XCTAssertEqual(
            Viewport.countChangeAction(
                oldCount: 30, newCount: 31,
                mode: viewport.mode,
                searchActive: false,
                incomingFollowSuppressed: viewport.incomingFollowSuppressed
            ),
            .none,
            "and an incoming message must not pull the transcript while a parent is held"
        )
    }

    func testVoiceAdvance_doesNotChangeMode() {
        let viewport = Viewport()
        viewport.scrollTo(messageId: "now-playing", anchor: .center, animated: false)
        XCTAssertEqual(viewport.mode, .following, "continuous voice is a guest, not a reader")
        XCTAssertNil(viewport.positionId, "and it does not bind history while following")
    }

    /// A guest scroll **inside** history re-binds the held row, so the bottom anchor cannot pull
    /// the reader back to the row they were on before the search jump.
    func testGuestScrollInHistoryRebindsTheHeldRow() {
        let viewport = Viewport()
        viewport.bindHistoryPosition("msg-40")
        viewport.scrollTo(messageId: "msg-12", anchor: .center, animated: false)
        XCTAssertEqual(viewport.positionId, "msg-12")
        XCTAssertEqual(viewport.mode, .readingHistory)
    }

    // MARK: - Holding the reader

    /// The reader keeps their row while the viewport changes shape under them. Measured limit
    /// (PR-0): the binding survives a growing pad, and does not survive content inserted above.
    func testReadingHistory_viewportGrow_doesNotMovePositionId() {
        let viewport = Viewport()
        viewport.noteUserInteraction()
        viewport.bindHistoryPosition("msg-40")

        // Composer grows (reply bar), then the keyboard collapses the safe area.
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 34, containerHeight: 700)
        viewport.updateScrollOffset(
            distanceFromBottom: 2378, contentFits: false,
            contentHeight: 3147, visibleMinY: 500, messageCount: 50
        )
        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 0, containerHeight: 420)
        viewport.updateScrollOffset(
            distanceFromBottom: 2378, contentFits: false,
            contentHeight: 3147, visibleMinY: 500, messageCount: 50
        )

        XCTAssertEqual(viewport.positionId, "msg-40", "the held row is the whole visit, not a window")
        XCTAssertEqual(viewport.mode, .readingHistory)
    }

    // MARK: - Keyboard hide

    /// Build 588's remaining half. The old path forced following **above** its own `wasVisible`
    /// guard, so a duplicated system delivery re-forced it.
    func testKeyboardHide_whileReadingHistory_doesNotYank() {
        XCTAssertEqual(
            Viewport.keyboardHideAction(mode: .readingHistory, keyboardWasVisible: true),
            .ignore
        )
    }

    func testKeyboardHide_whileFollowing_keepsFollowingWithoutWritingMode() {
        XCTAssertEqual(
            Viewport.keyboardHideAction(mode: .following, keyboardWasVisible: true),
            .keepFollowing
        )

        let viewport = Viewport()
        viewport.noteUserInteraction()
        viewport.bindHistoryPosition("msg-40")
        viewport.noteKeyboardHidden(wasVisible: true)
        XCTAssertEqual(viewport.mode, .readingHistory, "hide never writes mode")
        XCTAssertEqual(viewport.positionId, "msg-40")
    }

    func testKeyboardHide_duplicateDelivery_doesNotForceFollowing() {
        let viewport = Viewport()
        viewport.noteUserInteraction()
        viewport.bindHistoryPosition("msg-40")
        viewport.noteKeyboardHidden(wasVisible: true)
        viewport.noteKeyboardHidden(wasVisible: true)   // ~20ms later, same instance
        viewport.noteKeyboardHidden(wasVisible: false)
        XCTAssertEqual(viewport.mode, .readingHistory)
    }

    // MARK: - Missing-tail metric

    /// Not on the first packet. The transcript arrives before the anchor applies and before media
    /// reach their heights; alerting there fires on every healthy cold open.
    func testMissingTailMetric_doesNotFireOnFirstZeroToNTick() {
        XCTAssertFalse(
            Viewport.shouldReportMissingTail(
                stableQuietTicks: 1,
                insetSettling: false,
                messageCount: 50,
                contentHeight: 3952,
                padReady: true,
                userInteracted: false,
                alreadyPrimed: false,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: 0.01
            )
        )
    }

    /// The same 583 geometry, once it has held still. This is the failure the metric exists for.
    func testMissingTailMetric_build583_firesAfterStableTicks() {
        XCTAssertTrue(
            Viewport.shouldReportMissingTail(
                stableQuietTicks: ChatViewport.Threshold.missingTailStableTicks,
                insetSettling: false,
                messageCount: 50,
                contentHeight: 3952,
                padReady: true,
                userInteracted: false,
                alreadyPrimed: false,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: 0.01
            )
        )
    }

    /// A person who opens a chat and immediately swipes produces no event, and that is not the
    /// same as a landed tail — which is exactly why the soak needs a denominator.
    func testMissingTailMetric_silentAfterATouch() {
        XCTAssertFalse(
            Viewport.shouldReportMissingTail(
                stableQuietTicks: 9,
                insetSettling: false,
                messageCount: 50,
                contentHeight: 3952,
                padReady: true,
                userInteracted: true,
                alreadyPrimed: false,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: 0.01
            )
        )
    }

    func testMissingTailMetric_silentWhileAnInsetMoves() {
        XCTAssertFalse(
            Viewport.shouldReportMissingTail(
                stableQuietTicks: 9,
                insetSettling: true,
                messageCount: 50,
                contentHeight: 3952,
                padReady: true,
                userInteracted: false,
                alreadyPrimed: false,
                distanceFromBottom: -922,
                contentFits: false,
                visibleContentFraction: 0.01
            )
        )
    }

    func testMissingTailMetric_silentOnAHealthyOpen() {
        XCTAssertFalse(
            Viewport.shouldReportMissingTail(
                stableQuietTicks: 9,
                insetSettling: false,
                messageCount: 8,
                contentHeight: 2525,
                padReady: true,
                userInteracted: false,
                alreadyPrimed: false,
                distanceFromBottom: -83,
                contentFits: false,
                visibleContentFraction: 0.9
            )
        )
    }

    // MARK: - Ticks

    /// The denominator's raw material. A tick only counts as quiet if nothing was moving and
    /// nobody was touching; otherwise the count restarts.
    func testQuietTicksResetOnInsetMovementAndOnTouch() {
        let viewport = Viewport()
        viewport.noteInsetDelta(composer: 90, safeAreaBottom: 34, containerHeight: 700)
        for _ in 0..<3 {
            viewport.updateScrollOffset(
                distanceFromBottom: -83, contentFits: false,
                contentHeight: 2525, visibleMinY: 1800, messageCount: 8
            )
        }
        XCTAssertEqual(viewport.stableQuietTicks, 3)

        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 34, containerHeight: 700)
        XCTAssertEqual(viewport.stableQuietTicks, 0, "an inset moved")

        viewport.noteInsetDelta(composer: 140, safeAreaBottom: 34, containerHeight: 700)
        viewport.updateScrollOffset(
            distanceFromBottom: -83, contentFits: false,
            contentHeight: 2525, visibleMinY: 1800, messageCount: 8
        )
        XCTAssertEqual(viewport.stableQuietTicks, 1)

        viewport.noteUserInteraction()
        XCTAssertEqual(viewport.stableQuietTicks, 0, "somebody touched it")
    }

    /// A touch outranks the landing heuristic: someone who enters a chat and immediately swipes up
    /// must be able to leave following, landed or not.
    func testATouchPrimesTheLayoutAndLetsGeometryDecide() {
        let viewport = Viewport()
        viewport.noteUserInteraction()
        XCTAssertTrue(viewport.layoutPrimed)

        viewport.updateScrollOffset(
            distanceFromBottom: 2400, contentFits: false,
            contentHeight: 5000, visibleMinY: 400, messageCount: 50
        )
        XCTAssertEqual(viewport.mode, .readingHistory)
        XCTAssertTrue(viewport.showJumpButton)
    }
}
