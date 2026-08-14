//
//  ChatOpeningScrollTests.swift
//  ConstructMessengerTests
//
//  The two pure decisions behind "the chat is blank until you swipe" (TODO 34).
//
//  Both are about the same confusion: during the opening window, scroll geometry describes a
//  layout in flight, and the code read it as a reader's intent. There is nothing to assert on a
//  device here — the symptom is a rendering state — so the decisions are extracted and asserted
//  directly.
//

import XCTest
import SwiftUI   // ScrollPhase — isDragPhase is a decision over it
@testable import Construct_Messenger

@MainActor
final class ChatOpeningScrollTests: XCTestCase {

    private let atBottom: CGFloat = 0
    private let farUp: CGFloat = 900
    private let both = ChatScrollManager.ScrollFlags(autoScroll: true, showJumpButton: false)

    // MARK: - flags: geometry may not switch auto-scroll off while opening

    /// The defect. A first layout whose offset has not landed reports a large distance; reading it
    /// as "the user scrolled up" turned auto-scroll off, and every corrective pin then bailed at
    /// its own `shouldScrollToBottom` guard — leaving the list blank with no way back but a swipe.
    func testOpening_farFromBottomDoesNotDisableAutoScroll() {
        let next = ChatScrollManager.flags(
            current: both,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: false,
            userIsDragging: false,
            isOpening: true
        )
        XCTAssertTrue(next.autoScroll, "layout noise during the opening must not read as intent")
        XCTAssertFalse(next.showJumpButton, "no jump FAB over a list that has not landed yet")
    }

    /// Opening blocks only the OFF direction: landing at the bottom still re-arms auto-scroll.
    func testOpening_nearBottomStillEnablesAutoScroll() {
        let next = ChatScrollManager.flags(
            current: ChatScrollManager.ScrollFlags(autoScroll: false, showJumpButton: true),
            distanceFromBottom: atBottom,
            contentFits: false,
            keyboardVisible: false,
            userIsDragging: false,
            isOpening: true
        )
        XCTAssertTrue(next.autoScroll)
        XCTAssertFalse(next.showJumpButton)
    }

    /// Once settled, a large distance is exactly what it looks like: a reader in the history.
    func testSettled_farFromBottomDisablesAutoScrollAndShowsJump() {
        let next = ChatScrollManager.flags(
            current: both,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: false,
            userIsDragging: false,
            isOpening: false
        )
        XCTAssertFalse(next.autoScroll)
        XCTAssertTrue(next.showJumpButton)
    }

    func testContentFits_alwaysAutoScrollAndNoJump() {
        for opening in [true, false] {
            let next = ChatScrollManager.flags(
                current: ChatScrollManager.ScrollFlags(autoScroll: false, showJumpButton: true),
                distanceFromBottom: farUp,
                contentFits: true,
                keyboardVisible: false,
                userIsDragging: false,
                isOpening: opening
            )
            XCTAssertTrue(next.autoScroll, "opening=\(opening)")
            XCTAssertFalse(next.showJumpButton, "opening=\(opening)")
        }
    }

    /// Pre-existing rule, kept: keyboard animation produces transient distances, so a far-up
    /// reading while the keyboard is up changes nothing.
    func testKeyboardVisible_farUpLeavesFlagsUnchanged() {
        let current = ChatScrollManager.ScrollFlags(autoScroll: true, showJumpButton: false)
        let next = ChatScrollManager.flags(
            current: current,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: true,
            userIsDragging: false,
            isOpening: false
        )
        XCTAssertEqual(next, current)
    }

    // MARK: - Keyboard freeze must not outlive the keyboard animation
    //
    //  Device log 2026-08-14, 18:00:45 → 18:01:29. `KEYBOARD_TRACE: will SHOW` with no matching
    //  `will HIDE` for the rest of the session. In that window:
    //
    //      Loading more messages … Loaded 20 more messages (total: 72)
    //      … five more batches …
    //      Loaded 6 more messages (total: 158)
    //      ChatView: messages count changed to 158
    //      Scrolled to bottom (messageId: bottom, animated: true)   ← the yank
    //
    //  The person scrolled 128 messages up with the composer focused. The FAB never returned
    //  (`keyboardWillShow` cleared it, and `return current` could never set it again) and
    //  `autoScroll` could not switch off, so the count change read as "we are following" and
    //  animated them back to the newest message.
    //
    //  The branch was written as "while the keyboard is visible" and means "while the keyboard is
    //  animating". A finger on the list is the difference, and it is the same signal this file
    //  already trusts over the opening timer.

    func testKeyboardVisible_farUpWhileDragging_disablesAutoScrollAndShowsJump() {
        let next = ChatScrollManager.flags(
            current: both,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: true,
            userIsDragging: true,
            isOpening: false
        )
        XCTAssertFalse(next.autoScroll, "a finger on the list outranks the keyboard freeze")
        XCTAssertTrue(next.showJumpButton, "and the way back must be offered")
    }

    /// The freeze itself is kept: without a finger, keyboard geometry is still not intent.
    func testKeyboardVisible_farUpWithoutDragging_leavesFlagsUnchanged() {
        let current = ChatScrollManager.ScrollFlags(autoScroll: true, showJumpButton: false)
        let next = ChatScrollManager.flags(
            current: current,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: true,
            userIsDragging: false,
            isOpening: false
        )
        XCTAssertEqual(next, current)
    }

    /// After the finger lifts the freeze resumes, and freezing must preserve what the drag
    /// established — otherwise the reader is pulled back the moment they stop moving.
    func testDragEndedWithKeyboardUp_preservesReadingHistory() {
        let afterDrag = ChatScrollManager.ScrollFlags(autoScroll: false, showJumpButton: true)
        let next = ChatScrollManager.flags(
            current: afterDrag,
            distanceFromBottom: farUp,
            contentFits: false,
            keyboardVisible: true,
            userIsDragging: false,
            isOpening: false
        )
        XCTAssertEqual(next, afterDrag, "the freeze preserves the drag's verdict, it does not undo it")
    }

    /// Raising the keyboard must not take away the reader's way back. Before 2026-08-14 it did,
    /// unconditionally, and the freeze in `flags` then made the loss permanent for the session.
    func testKeyboardShow_whileReadingHistory_keepsJumpButton() {
        XCTAssertFalse(
            ChatScrollManager.shouldClearJumpButtonOnKeyboardShow(
                isFollowing: false, jumpButtonVisible: true
            ),
            "tapping the composer is not a request to lose the way back to the newest message"
        )
    }

    func testKeyboardShow_whileFollowing_clearsAStaleJumpButton() {
        XCTAssertTrue(
            ChatScrollManager.shouldClearJumpButtonOnKeyboardShow(
                isFollowing: true, jumpButtonVisible: true
            )
        )
        XCTAssertFalse(
            ChatScrollManager.shouldClearJumpButtonOnKeyboardShow(
                isFollowing: true, jumpButtonVisible: false
            ),
            "nothing to clear"
        )
    }

    /// `.animating` is our own corrective pin. Counting it as a drag would let a pin's motion
    /// read as the person's intent — and the pin runs precisely when the layout is least settled.
    func testCorrectivePinMotionIsNotADrag() {
        XCTAssertFalse(
            ChatScrollManager.isDragPhase(.animating),
            "`.animating` is our own corrective pin — reading it as intent lets a pin justify itself"
        )
        XCTAssertFalse(ChatScrollManager.isDragPhase(.idle))
    }

    func testFingerAndItsMomentumBothCountAsDrag() {
        XCTAssertTrue(ChatScrollManager.isDragPhase(.tracking))
        XCTAssertTrue(ChatScrollManager.isDragPhase(.interacting))
        XCTAssertTrue(
            ChatScrollManager.isDragPhase(.decelerating),
            "the finger has left but the movement is still theirs"
        )
    }

    /// The instance path, so the wiring from phase to flag is covered too.
    func testNoteScrollPhaseSetsAndClearsDragging() {
        let manager = ChatScrollManager()
        XCTAssertFalse(manager.isUserDragging)
        manager.noteScrollPhase(.tracking)
        XCTAssertTrue(manager.isUserDragging)
        manager.noteScrollPhase(.animating)
        XCTAssertFalse(manager.isUserDragging, "a pin animation must not keep the drag latched")
    }

    // MARK: - countChangeAction

    /// 0 → N is the chat opening, whatever the flags say. `shouldScrollToBottom` at that moment
    /// describes a transcript that did not exist, so it cannot be evidence about this one.
    func testZeroToN_opensEvenWithAutoScrollOff() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 0, newCount: 30, autoScrollOn: false, searchActive: false, isOpening: false
            ),
            .openTranscript
        )
    }

    /// Growth during opening (media / FRC — load-more is gated off now) must stay non-animated.
    func testGrowthDuringOpening_isCorrectivePinNotAnimated() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 30, newCount: 50, autoScrollOn: true, searchActive: false, isOpening: true
            ),
            .correctivePin
        )
    }

    // MARK: - shouldLoadOlderHistory (TODO 34 — unprompted load-more)

    private let atTop: CGFloat = 0
    private let midList: CGFloat = 800

    /// The defect: LazyVStack materialises the top sentinel on first layout while bottom-anchored.
    /// Opening must refuse so entry does not grow 30 → 50.
    func testLoadOlder_refusesDuringOpeningEvenAtTop() {
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: true,
                contentFits: false,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: true,
                contentFits: true,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            ),
            "contentFits fill must wait until opening ends"
        )
    }

    /// Bottom-anchored entry after opening: top is far from the viewport → no load.
    func testLoadOlder_refusesWhenFollowingOverflow() {
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: false,
                visibleMinY: midList,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    /// Person scrolled to the oldest edge → widen the window.
    func testLoadOlder_allowsNearTopWhileReadingHistory() {
        XCTAssertTrue(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: false,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
        XCTAssertTrue(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: false,
                visibleMinY: ChatScrollManager.Threshold.nearTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            ),
            "at the threshold still counts as near top"
        )
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: false,
                visibleMinY: ChatScrollManager.Threshold.nearTop + 1,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    /// Short initial page of a longer chat: fill until the list can scroll (after opening).
    func testLoadOlder_allowsContentFitsFillAfterOpening() {
        XCTAssertTrue(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: true,
                visibleMinY: midList,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    func testLoadOlder_respectsBusyAndSearchAndExhausted() {
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true, isOpening: false, contentFits: true, visibleMinY: atTop,
                isSearchActive: true, isLoadingMore: false, hasMoreMessages: true
            )
        )
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true, isOpening: false, contentFits: true, visibleMinY: atTop,
                isSearchActive: false, isLoadingMore: true, hasMoreMessages: true
            )
        )
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true, isOpening: false, contentFits: true, visibleMinY: atTop,
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: false
            )
        )
    }

    /// Device log 2026-08-14, five times in one session — the defect `isOpening` was meant to
    /// stop and never got the chance:
    ///
    ///     FRC initial fetch: 30 messages (oldest-first)
    ///     Loading more messages before 2026-08-11 10:53:41 [trigger=indicatorAppeared]
    ///     Loaded 20 more messages (total: 50)
    ///     ChatView: messages count changed to 30      ← beginOpening only here
    ///     PIN arm reason=opening
    ///
    /// The sentinel's `onAppear` runs before the transcript count ever changes, so `isOpening` is
    /// still false. What admitted the fetch was `visibleMinY` holding its initial `0`, because no
    /// geometry tick had happened yet — and `0 <= nearTop` is true. Unmeasured must not read as
    /// "the person is at the oldest edge".
    func testLoadOlder_refusesBeforeViewportTopIsMeasured() {
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: false,
                isOpening: false,
                contentFits: false,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            ),
            "visibleMinY == 0 before the first tick is an initial value, not a viewport at the top"
        )
        XCTAssertFalse(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: false,
                isOpening: false,
                contentFits: true,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            ),
            "contentFits is also just its initial false before the first tick — no prefetch either"
        )
    }

    /// The guard must not become permanent: once a tick lands, the old behaviour is unchanged.
    func testLoadOlder_allowsOnceViewportTopIsMeasured() {
        XCTAssertTrue(
            ChatScrollManager.shouldLoadOlderHistory(
                hasMeasuredViewportTop: true,
                isOpening: false,
                contentFits: false,
                visibleMinY: atTop,
                isSearchActive: false,
                isLoadingMore: false,
                hasMoreMessages: true
            )
        )
    }

    /// Instance path, in the order the device produces it: the sentinel asks before any geometry
    /// tick, then a bottom-anchored tick lands, and only a real scroll to the top may widen.
    func testLoadOlder_instanceRefusesUntilFirstGeometryTick() {
        let manager = ChatScrollManager()
        XCTAssertFalse(
            manager.shouldLoadOlderHistory(
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: true
            ),
            "fresh manager: nothing has been measured, the sentinel must be refused"
        )
        // Bottom-anchored entry: viewport top is far down the content.
        manager.updateScrollOffset(
            distanceFromBottom: 0,
            contentFits: false,
            contentHeight: 4000,
            visibleMinY: 3200
        )
        XCTAssertFalse(
            manager.shouldLoadOlderHistory(
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: true
            ),
            "measured and far from the top → still no"
        )
        manager.updateScrollOffset(
            distanceFromBottom: 3800,
            contentFits: false,
            contentHeight: 4000,
            visibleMinY: 10
        )
        XCTAssertTrue(
            manager.shouldLoadOlderHistory(
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: true
            ),
            "person actually scrolled to the oldest edge"
        )
    }

    /// Instance mirror reads last geometry tick (contentFits stored by updateScrollOffset).
    func testLoadOlder_instanceUsesStoredGeometry() {
        let manager = ChatScrollManager()
        manager.beginOpening(settleAfterMs: 10_000)
        manager.updateScrollOffset(
            distanceFromBottom: 0,
            contentFits: true,
            contentHeight: 200,
            visibleMinY: 0
        )
        XCTAssertFalse(
            manager.shouldLoadOlderHistory(
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: true
            ),
            "opening still blocks"
        )
        manager.endOpening()
        XCTAssertTrue(
            manager.shouldLoadOlderHistory(
                isSearchActive: false, isLoadingMore: false, hasMoreMessages: true
            ),
            "after opening, contentFits fill is allowed"
        )
    }

    func testGrowthAfterOpening_isAnimatedFollow() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 50, newCount: 51, autoScrollOn: true, searchActive: false, isOpening: false
            ),
            .animatedFollow
        )
    }

    /// FRC thrash shrinks the list (83 → 51 → 67 in the logs). Following a drop animated to bottom
    /// while the list was rebuilding — the black flash.
    func testCountDrop_doesNothing() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 83, newCount: 51, autoScrollOn: true, searchActive: false, isOpening: false
            ),
            .none
        )
    }

    func testReaderScrolledUp_isNotFollowed() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 50, newCount: 51, autoScrollOn: false, searchActive: false, isOpening: false
            ),
            .none
        )
    }

    /// Search owns the scroll position while it is active — including the opening.
    func testSearchActive_neverScrolls() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 0, newCount: 30, autoScrollOn: true, searchActive: true, isOpening: false
            ),
            .none
        )
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 50, newCount: 51, autoScrollOn: true, searchActive: true, isOpening: false
            ),
            .none
        )
    }

    func testEmptyTranscript_doesNothing() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 0, newCount: 0, autoScrollOn: true, searchActive: false, isOpening: false
            ),
            .none
        )
    }

    // MARK: - The window itself

    func testBeginOpening_armsWindowAndForcesAutoScrollBackOn() {
        let manager = ChatScrollManager()
        manager.updateScrollOffset(distanceFromBottom: farUp)   // blank-layout noise latches it off
        XCTAssertFalse(manager.shouldScrollToBottom)

        manager.beginOpening(settleAfterMs: 10_000)
        XCTAssertTrue(manager.isOpening)
        XCTAssertTrue(manager.shouldScrollToBottom,
                      "the opening must not inherit a reading position from a list that was empty")

        // And the noise can no longer switch it off while the window is up.
        manager.updateScrollOffset(distanceFromBottom: farUp)
        XCTAssertTrue(manager.shouldScrollToBottom)
    }

    /// A person swiping outranks the settle timer — otherwise we pin back someone who entered a
    /// chat and immediately went up to read.
    func testEndOpening_releasesTheWindow() {
        let manager = ChatScrollManager()
        manager.beginOpening(settleAfterMs: 10_000)
        manager.endOpening()
        XCTAssertFalse(manager.isOpening)

        manager.updateScrollOffset(distanceFromBottom: farUp)
        XCTAssertFalse(manager.shouldScrollToBottom, "after the window, geometry is intent again")
    }

    func testOpeningWindowExpiresOnItsOwn() async throws {
        let manager = ChatScrollManager()
        manager.beginOpening(settleAfterMs: 60)
        XCTAssertTrue(manager.isOpening)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(manager.isOpening, "the settle timer must close the window")
    }

    // MARK: - The transcript is measured at a height it does not keep (build 583)

    //  Every opening in the 2026-08-06 log:
    //
    //      596 → 2143 → 4118 → 3952 → 5901 → 5792   ← the corrective pin lands here
    //      …3s… content=3952pt viewport=[3942…4874] fromBottom=-922 autoScroll=true
    //
    //  The pin anchored to a 5792pt transcript; it settled at 3952pt, and the viewport was left
    //  922 points past the end of the content: ten points of transcript on screen and a screenful
    //  of nothing beneath it. That is the blank chat.






    // MARK: - A transcript shorter than the viewport

    /// Build 593, right after sending a three-photo album into an eleven-message chat:
    ///
    ///     SCROLL_RECOVER: mode=following, newest off screen for 0.0s,
    ///         42% of the viewport shows transcript (contentHeight=798pt fromBottom=-538)
    ///
    /// 798pt of content against a viewport half again as tall, and `fromBottom` negative because
    /// there is nothing to scroll — the newest row simply had not been laid out yet. Coverage of
    /// 42% is the correct fill level for a short chat, not evidence of a stranded viewport.
    func testShortTranscriptDoesNotRecoverOnCoverageAlone() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 0.0, visibleContentFraction: 0.42,
                distanceFromBottom: -538, contentFits: true, autoScrollOn: true, isOpening: false,
                searchActive: false
            ),
            "a chat too short to fill the screen is not stranded — recovering yanks the reader for nothing"
        )
    }

    /// The nearBottom guard cannot catch it: -538 passes `<= 60` easily. Only knowing the content
    /// fits does.
    func testNegativeDistanceIsNotEvidenceOfBeingAnchored() {
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 0.0, visibleContentFraction: 0.42,
                distanceFromBottom: -538, contentFits: false, autoScrollOn: true, isOpening: false,
                searchActive: false
            ),
            "same geometry with a transcript taller than the viewport IS the stranded case"
        )
    }

    /// The blank chat this rule exists for can happen in a short transcript too, and duration is
    /// the witness that still works there — a newest row missing for a full second is blank
    /// whether or not the content fits.
    func testShortTranscriptStillRecoversWhenTheNewestRowStaysMissing() {
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 1.5, visibleContentFraction: 0.42,
                distanceFromBottom: -538, contentFits: true, autoScrollOn: true, isOpening: false,
                searchActive: false
            )
        )
    }

    // MARK: - Auto-scroll must keep the promise it makes

    /// The second half of the defect, and the one a distance threshold cannot express: auto-scroll
    /// claims the newest message is on screen, and `distance <= threshold` accepted −922 exactly as
    /// readily as 0. Stated as visibility because an inset chat is legitimately negative and any
    /// numeric cutoff between "composer inset" and "stranded" would move with the composer.
    func testPinnedButLastMessageOffScreenRecovers() {
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, distanceFromBottom: -84, contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    func testLastMessageVisibleNeedsNoRecovery() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01, distanceFromBottom: -84, contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// A person who scrolled up has auto-scroll off, and the last message being off screen is
    /// exactly what they asked for.
    func testReadingUpTheTranscriptIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, distanceFromBottom: -84, contentFits: false, autoScrollOn: false, isOpening: false, searchActive: false
            ),
            "recovering here would yank a reader back to the bottom on every scroll"
        )
    }

    /// During the opening the offset has not landed and the corrective pin series owns the window;
    /// a second source of pins there would fight it.
    func testOpeningWindowOwnsItsOwnCorrection() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, distanceFromBottom: -84, contentFits: false, autoScrollOn: true, isOpening: true, searchActive: false
            )
        )
    }

    /// Search deliberately puts the transcript somewhere other than the end.
    func testSearchIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, distanceFromBottom: -84, contentFits: false, autoScrollOn: true, isOpening: false, searchActive: true
            )
        )
    }

    /// The manager starts believing the newest message is on screen, so an empty or not-yet-drawn
    /// transcript never reads as stranded.
    func testManagerStartsNotStranded() {
        XCTAssertTrue(ChatScrollManager().isLastMessageVisible)
    }

    // MARK: - Build 587: geometry cannot see an unrendered row
    //
    // 586 shipped geometry as the casting vote and the blank chat came back. The log:
    //
    //     16:58:47  SCROLL_ANCHOR last message left the viewport (0b9bd1ab…)
    //     16:58:47  SCROLL_GEO content=4961pt viewport=[4113…5045] fromBottom=-84 mode=opening
    //     …four seconds of nothing…
    //     16:58:51  SCROLL_ANCHOR last message visible (0b9bd1ab…, idx=49/50)
    //
    // 848 of 932 viewport points "showing transcript" — 91 % — while the screen was empty. A
    // `LazyVStack` reports height for rows it has not rendered, so the content height was itself
    // the lie, and a coverage ratio derived from it could only agree with the lie. The chat filled
    // the instant the keyboard forced a re-layout: the rows were missing, not the position.
    //
    // The witness that CAN see this is the row callback — the one 585 demoted for flapping. What
    // separates the flap from the failure is duration, measured in both logs: 585 had 120 absence
    // episodes, 112 under a second; 587's blanks lasted 4 s and 26 s.

    func testNewestRowMissingBehindHealthyGeometryStillRecovers() {
        let fraction = ChatScrollManager.visibleContentFraction(
            contentHeight: 4961, visibleMinY: 4113, distanceFromBottom: -84
        )
        XCTAssertGreaterThan(fraction, ChatScrollManager.strandedCoverageFloor,
                             "the 587 geometry reads healthy — that is the whole problem")
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 4, visibleContentFraction: fraction, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            ),
            "geometry no longer holds a veto over a row that is provably not on screen"
        )
    }

    /// The 585 storm, which duration — not arbitration — is what prevents.
    func testMomentaryDisappearanceDuringRematerialisationIsIgnored() {
        let fraction = ChatScrollManager.visibleContentFraction(
            contentHeight: 4694, visibleMinY: 4130, distanceFromBottom: -91
        )
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 0.1, visibleContentFraction: fraction, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            ),
            "a flicker cannot sustain an absence; 112 of 585's 120 episodes were under a second"
        )
    }

    func testAbsenceMustOutlastTheGraceExactly() {
        let grace = ChatScrollManager.newestMessageAbsenceGrace
        func stranded(after seconds: TimeInterval) -> Bool {
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: seconds, visibleContentFraction: 0.9, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        }
        XCTAssertFalse(stranded(after: grace - 0.01))
        XCTAssertTrue(stranded(after: grace))
    }

    /// The 583 case: the viewport is off the end of the transcript. Coverage answers immediately,
    /// with no grace to wait out — there is nothing transient about a viewport past the content.
    func testViewportOffTheTranscriptRecoversWithoutWaiting() {
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 0, visibleContentFraction: 0.01, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// …but never over a visible newest row. A short transcript covers little of the viewport and
    /// is perfectly healthy; coverage says where the viewport is, not whether anything is drawn.
    func testCoverageNeverOverridesAVisibleNewestRow() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    // MARK: - Build 588: auto-scroll on is not proof of being at the bottom
    //
    // The rule above fired twice on device, both times on a reader in the history, both a second
    // before `KEYBOARD_TRACE: will HIDE`:
    //
    //     newest off screen for 1.1s, 94% of the viewport shows transcript
    //         (contentHeight=3147pt fromBottom=2378) — re-pinning
    //     newest off screen for 1.1s, 100% …    (contentHeight=3181pt fromBottom=626)
    //
    // `flags(current:…)` returns `current` unchanged while the keyboard is visible and the
    // viewport is not near the bottom — a deliberate latch against transient keyboard distances.
    // So someone who scrolls up with the keyboard open keeps auto-scroll on, and the guard that
    // was supposed to protect them said nothing. They were yanked to the end mid-read.

    func testReaderScrolledUpWithTheKeyboardOpenIsNotYankedDown() {
        for distance in [CGFloat(2378), 626] {   // both device readings
            XCTAssertFalse(
                ChatScrollManager.shouldRecoverStrandedViewport(
                    lastMessageVisible: false, newestHiddenFor: 1.1, visibleContentFraction: 0.94,
                    distanceFromBottom: distance,
                    contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
                ),
                "fromBottom=\(distance): the newest message is off screen because the reader put it there"
            )
        }
    }

    func testTheBlankChatItselfIsStillAnchored() {
        // 587's blank sat at fromBottom=-84 — anchored is negative or near zero, never hundreds up.
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 4, visibleContentFraction: 0.91,
                distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    func testTheAnchorAllowanceEndsAtTheNearBottomThreshold() {
        func stranded(at distance: CGFloat) -> Bool {
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 4, visibleContentFraction: 0.91,
                distanceFromBottom: distance,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        }
        XCTAssertTrue(stranded(at: ChatScrollManager.Threshold.nearBottom))
        XCTAssertFalse(stranded(at: ChatScrollManager.Threshold.nearBottom + 1))
    }

    /// Neither route may override the guards. A reader who scrolled up asked for exactly this.
    func testAPersistentAbsenceStillRespectsTheGuards() {
        for (auto, opening, search) in [(false, false, false), (true, true, false), (true, false, true)] {
            XCTAssertFalse(
                ChatScrollManager.shouldRecoverStrandedViewport(
                    lastMessageVisible: false, newestHiddenFor: 30, visibleContentFraction: 0.01, distanceFromBottom: -84,
                    contentFits: false, autoScrollOn: auto, isOpening: opening, searchActive: search
                ),
                "autoScroll=\(auto) opening=\(opening) search=\(search)"
            )
        }
    }

    /// The flag follows what the transcript reports, in both directions.
    func testVisibilityIsRecorded() {
        let manager = ChatScrollManager()
        manager.noteLastMessageVisible(false, searchActive: false)
        XCTAssertFalse(manager.isLastMessageVisible)
        manager.noteLastMessageVisible(true, searchActive: false)
        XCTAssertTrue(manager.isLastMessageVisible)
    }

    // MARK: - A height change is a measurement, not an event (build 584)

    //  The 583 fix re-pinned on every height change in either direction. Build 584 stopped going
    //  blank and started flickering, because one opening reports seven changes inside a second:
    //
    //      91 → 596 → 4524 → 4755 → 4673 → 5948 → 5210 → 4673
    //
    //  It ends where it was three steps earlier. Each re-pin carried a leading `0` tick, so each
    //  intermediate measurement became a visible scroll. Only where the height lands deserves one.




    // MARK: - PinPolicy is the only delay table

    /// Every pin reason has a non-empty series; height settle is the only one that must never
    /// lead with 0 (intermediate layout measurements must not become visible jumps).
    func testPinPolicy_heightSettleHasNoLeadingZero() {
        let delays = ChatScrollManager.PinPolicy.delays(for: .heightSettle)
        XCTAssertFalse(delays.isEmpty)
        XCTAssertFalse(delays.contains(0))
        XCTAssertEqual(delays, ChatScrollManager.heightSettleDelaysMs)
    }

    func testPinPolicy_openingUsesImmediateFirstTick() {
        let opening = ChatScrollManager.PinPolicy.delays(for: .opening)
        XCTAssertEqual(opening.first, 0)
        XCTAssertGreaterThanOrEqual(opening.count, 3)
    }

    func testPinPolicy_everyReasonHasDelays() {
        for reason in ChatScrollManager.PinReason.allCases {
            XCTAssertFalse(
                ChatScrollManager.PinPolicy.delays(for: reason).isEmpty,
                "reason \(reason.rawValue) must map to a pin series"
            )
        }
    }

    // MARK: - ViewportMode derivation

    func testViewportMode_openingWinsOverFlags() {
        let manager = ChatScrollManager()
        manager.beginOpening(settleAfterMs: 10_000)
        XCTAssertEqual(manager.viewportMode, .opening)
        // Even if flags would say reading history, opening owns the mode.
        manager.shouldScrollToBottom = false
        XCTAssertEqual(manager.viewportMode, .opening)
    }

    func testViewportMode_followingVsReadingHistory() {
        let manager = ChatScrollManager()
        XCTAssertEqual(manager.viewportMode, .following)
        manager.shouldScrollToBottom = false
        XCTAssertEqual(manager.viewportMode, .readingHistory)
        manager.shouldScrollToBottom = true
        XCTAssertEqual(manager.viewportMode, .following)
    }

    /// handleTranscriptCountChange is the single entry ChatView uses — 0→N must open.
    func testHandleTranscriptCountChange_zeroToNBeginsOpening() {
        let manager = ChatScrollManager()
        manager.handleTranscriptCountChange(oldCount: 0, newCount: 30, searchActive: false)
        XCTAssertTrue(manager.isOpening)
        XCTAssertEqual(manager.viewportMode, .opening)
        XCTAssertTrue(manager.shouldScrollToBottom)
    }

    func testHandleTranscriptCountChange_searchIsNoOp() {
        let manager = ChatScrollManager()
        manager.handleTranscriptCountChange(oldCount: 0, newCount: 30, searchActive: true)
        XCTAssertFalse(manager.isOpening)
        XCTAssertEqual(manager.viewportMode, .following)
    }

    // MARK: - Keyboard pin coalesce (build 586: one willShow → two PIN arm)

    //  Log 586: one KEYBOARD_TRACE will SHOW, two `PIN arm reason=keyboardShow` — two live
    //  ChatScrollManager instances both subscribed. will HIDE arrived twice ~20ms apart and each
    //  doubled again (4 arms). One pin series is enough; the rest only restarts pinTask.

    func testKeyboardPin_sameReasonWithinWindowIsCoalesced() {
        XCTAssertFalse(
            ChatScrollManager.shouldArmKeyboardPin(
                reason: .keyboardShow,
                now: 10.05,
                lastReason: .keyboardShow,
                lastTime: 10.0
            ),
            "second manager / double NC within 200ms must not arm another series"
        )
        XCTAssertFalse(
            ChatScrollManager.shouldArmKeyboardPin(
                reason: .keyboardHide,
                now: 10.02,
                lastReason: .keyboardHide,
                lastTime: 10.0
            )
        )
    }

    func testKeyboardPin_oppositeReasonIsNotCoalesced() {
        XCTAssertTrue(
            ChatScrollManager.shouldArmKeyboardPin(
                reason: .keyboardHide,
                now: 10.05,
                lastReason: .keyboardShow,
                lastTime: 10.0
            ),
            "hide after show is a real transition even inside the window"
        )
    }

    func testKeyboardPin_sameReasonAfterWindowArmsAgain() {
        let window = ChatScrollManager.PinPolicy.keyboardPinCoalesceSeconds
        XCTAssertTrue(
            ChatScrollManager.shouldArmKeyboardPin(
                reason: .keyboardShow,
                now: 10.0 + window + 0.01,
                lastReason: .keyboardShow,
                lastTime: 10.0
            )
        )
    }

    func testKeyboardShow_sameHeightIsNoOp() {
        XCTAssertFalse(
            ChatScrollManager.shouldApplyKeyboardShow(newHeight: 336, previousHeight: 336)
        )
        XCTAssertTrue(
            ChatScrollManager.shouldApplyKeyboardShow(newHeight: 336, previousHeight: 0),
            "first show on this instance"
        )
        XCTAssertTrue(
            ChatScrollManager.shouldApplyKeyboardShow(newHeight: 380, previousHeight: 336),
            "keyboard resize (emoji bar / floating) still re-pins"
        )
    }

    // MARK: - Keyboard hide must not force following
    //
    //  Study 2026-08-14. `keyboardWillHide` ran, unconditionally and above its own
    //  `guard wasVisible`:
    //
    //      self.shouldScrollToBottom = true            // 878
    //      self.shouldShowScrollToBottomButton = false // 879
    //      guard wasVisible else { return }            // 880
    //
    //  Build 588 closed this yank for a *visible* keyboard through stranded-recover and left the
    //  hide path alone: a reader who scrolled up, tapped the composer and dismissed the keyboard
    //  was still dragged to the newest message. The placement above the guard is a second defect —
    //  the system's ~20ms redelivery re-forced auto-scroll even when the first hide was correctly
    //  a no-op, which is exactly what the comment on that guard claims cannot happen.

    func testKeyboardHide_whileReadingHistory_doesNotYank() {
        XCTAssertEqual(
            ChatScrollManager.keyboardHideAction(mode: .readingHistory, keyboardWasVisible: true),
            .ignore,
            "dismissing the keyboard is not a request to leave history"
        )
    }

    func testKeyboardHide_whileFollowing_staysFollowing() {
        XCTAssertEqual(
            ChatScrollManager.keyboardHideAction(mode: .following, keyboardWasVisible: true),
            .keepFollowing
        )
    }

    /// The opening window belongs to the corrective pin series. Someone who has touched nothing
    /// has not left the tail, so a hide during opening must not be read as intent either way.
    func testKeyboardHide_whileOpening_keepsFollowing() {
        XCTAssertEqual(
            ChatScrollManager.keyboardHideAction(mode: .opening, keyboardWasVisible: true),
            .keepFollowing
        )
    }

    /// Not redundant with the history case: this is the one that fails if the flag writes move
    /// back above `guard wasVisible`. The first hide is real, the second is the system's ~20ms
    /// redelivery — by then `keyboardHeight` is already 0, so `keyboardWasVisible` is false and
    /// nothing may be written a second time, in any mode.
    func testKeyboardHide_duplicateDelivery_doesNotForceFollowing() {
        for mode in [ChatScrollManager.ViewportMode.following,
                     .readingHistory,
                     .opening] {
            XCTAssertEqual(
                ChatScrollManager.keyboardHideAction(mode: mode, keyboardWasVisible: false),
                .ignore,
                "redelivered hide must not touch scroll state (mode: \(mode))"
            )
        }
    }

    // MARK: - Composer inset pin coalesce

    /// Media/reply height settles in several geometry steps; each used to arm `[0, 120]`.
    func testComposerInsetPin_coalescesBurstInsideWindow() {
        let window = ChatScrollManager.PinPolicy.composerInsetCoalesceSeconds
        XCTAssertTrue(
            ChatScrollManager.shouldArmComposerInsetPin(now: 10.0, lastTime: 0),
            "first arm on a manager (lastTime never set)"
        )
        XCTAssertFalse(
            ChatScrollManager.shouldArmComposerInsetPin(now: 10.0 + window / 2, lastTime: 10.0),
            "reply bar + media strip + thumbnail steps must share one series"
        )
        XCTAssertTrue(
            ChatScrollManager.shouldArmComposerInsetPin(now: 10.0 + window + 0.01, lastTime: 10.0),
            "a later settle after the window still re-pins"
        )
    }

    /// Instance path: following + rapid noteComposerHeightChanged arms once inside the window.
    func testComposerInsetPin_instanceSkipsSecondArmInBurst() {
        let manager = ChatScrollManager()
        manager.shouldScrollToBottom = true
        manager.noteComposerHeightChanged(now: 20.0)
        // Second call must not throw / re-arm; last time stays 20.0 so a third inside the window is also skipped.
        manager.noteComposerHeightChanged(now: 20.05)
        XCTAssertFalse(
            ChatScrollManager.shouldArmComposerInsetPin(
                now: 20.1,
                lastTime: 20.0
            )
        )
        // After the window, pure decision allows again (instance would arm on next call).
        let window = ChatScrollManager.PinPolicy.composerInsetCoalesceSeconds
        XCTAssertTrue(
            ChatScrollManager.shouldArmComposerInsetPin(now: 20.0 + window + 0.01, lastTime: 20.0)
        )
    }

    func testComposerInsetPin_doesNotPinWhenReadingHistory() {
        let manager = ChatScrollManager()
        manager.shouldScrollToBottom = false
        manager.noteComposerHeightChanged(now: 30.0)
        // Never armed → lastTime still 0 → pure "first arm" would still be true, but the guard
        // on shouldScrollToBottom means we did not update lastTime. A later follow still arms.
        XCTAssertTrue(
            ChatScrollManager.shouldArmComposerInsetPin(now: 30.0, lastTime: 0),
            "refusing while reading must not burn the coalesce slot"
        )
    }

    /// Probe logs drowned thermal exports (259 SCROLL_GEO in 4.5 min). Default must stay off.
    func testVerboseGeometryLoggingDefaultsOff() {
        XCTAssertFalse(
            ChatScrollManager.verboseGeometryLogging,
            "export sessions should not pay for geometry probes unless someone flips the flag"
        )
    }

    // MARK: - The loop I built, and the geometry that breaks it (build 585)

    //  583 made a height change a re-pin trigger; 584 debounced it. Build 585 shows why neither
    //  worked: in a lazy list a pin changes which cells are materialised, which changes the
    //  measured height, which triggers another pin. 631 re-pins and 115 recoveries in one session,
    //  the height oscillating 2645 ↔ 3000 ↔ 3151 forever. The height trigger is deleted.
    //
    //  The recovery rule survived, but it had the same flaw in miniature: `onDisappear` for the
    //  last row fires transiently during re-materialisation, and it reported "off screen" at
    //  fromBottom=-91 — with the viewport at the bottom and 90 % of it covered by transcript.
    //  Geometry now has the casting vote.

    /// The blank chat: content 3952, viewport [3942…4874]. Ten points of transcript under a
    /// screenful of nothing.
    func testBlankTranscriptIsAlmostNoCoverage() {
        let fraction = ChatScrollManager.visibleContentFraction(
            contentHeight: 3952, visibleMinY: 3942, distanceFromBottom: -922
        )
        XCTAssertLessThan(fraction, ChatScrollManager.strandedCoverageFloor)
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: fraction, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// The 585 false positive: at rest at the bottom, only the composer inset below the content.
    /// The row callback said "gone"; the screen was full.
    func testAtRestWithComposerInsetIsNotStranded() {
        let fraction = ChatScrollManager.visibleContentFraction(
            contentHeight: 2645, visibleMinY: 1804, distanceFromBottom: -91
        )
        XCTAssertGreaterThan(fraction, ChatScrollManager.strandedCoverageFloor)
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 0.1, visibleContentFraction: fraction, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            ),
            "recovering a chat that is already at the bottom is what made it jerk"
        )
    }

    /// A ratio, not a point count — the inset can grow (keyboard + reply bar) without ever
    /// approaching half the screen, which is why no pt threshold was safe.
    func testKeyboardSizedInsetIsStillNotStranded() {
        let fraction = ChatScrollManager.visibleContentFraction(
            contentHeight: 4000, visibleMinY: 3200, distanceFromBottom: -340
        )
        XCTAssertGreaterThan(fraction, ChatScrollManager.strandedCoverageFloor)
    }

    /// An unmeasured layout must never read as stranded — that would pin on first appear, before
    /// anything has been laid out.
    func testUnknownGeometryReadsAsFullyCovered() {
        XCTAssertEqual(
            ChatScrollManager.visibleContentFraction(
                contentHeight: 0, visibleMinY: 0, distanceFromBottom: 0
            ),
            1
        )
    }

    /// Scrolled entirely past the end: no overlap at all.
    func testViewportFullyPastTheEndIsZeroCoverage() {
        XCTAssertEqual(
            ChatScrollManager.visibleContentFraction(
                contentHeight: 1000, visibleMinY: 1200, distanceFromBottom: -900
            ),
            0
        )
    }

    /// Both witnesses are required. Geometry alone must not pin while the newest row is on screen —
    /// during the opening the fraction is legitimately small and the pin series owns that window.
    func testLowCoverageAloneDoesNotRecoverWhileTheNewestRowIsVisible() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01, distanceFromBottom: -84,
                contentFits: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }
}
