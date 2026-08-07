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
            isOpening: false
        )
        XCTAssertEqual(next, current)
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

    /// The regression this fixes. The unprompted load-more grows 30 → 50 on every chat entry; with
    /// the opening window mistakenly considered over, this took `.animatedFollow` — an animated
    /// scroll through the composer-inset settle, which dematerializes the LazyVStack.
    func testGrowthDuringOpening_isCorrectivePinNotAnimated() {
        XCTAssertEqual(
            ChatScrollManager.countChangeAction(
                oldCount: 30, newCount: 50, autoScrollOn: true, searchActive: false, isOpening: true
            ),
            .correctivePin
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

    /// The regression. `shouldRepinForHeightChange` said "growth only" on the assumption that a
    /// shrink is handled by `.defaultScrollAnchor`. A 1840pt collapse is not.
    func testShrinkWhilePinnedRepins() {
        XCTAssertTrue(
            ChatScrollManager.shouldRepinForHeightChange(
                previousHeight: 5792, currentHeight: 3952, autoScrollOn: true, isOpening: false
            ),
            "the pin anchored to a height the transcript no longer has"
        )
    }

    /// Growth still re-pins — media resolving under a bottom-anchored list.
    func testGrowthWhilePinnedStillRepins() {
        XCTAssertTrue(
            ChatScrollManager.shouldRepinForHeightChange(
                previousHeight: 3952, currentHeight: 5792, autoScrollOn: true, isOpening: false
            )
        )
    }

    /// The reason the old rule gave for excluding shrink was "it would fight a user whose keyboard
    /// just dismissed". That user does not have auto-scroll on, so the guard already covered it —
    /// pinned here in case someone re-derives the old argument.
    func testShrinkIsIgnoredWhenNotPinned() {
        XCTAssertFalse(
            ChatScrollManager.shouldRepinForHeightChange(
                previousHeight: 5792, currentHeight: 3952, autoScrollOn: false, isOpening: false
            ),
            "a person who scrolled up must never be yanked back by a layout change"
        )
    }

    /// Sub-threshold changes in either direction are layout noise; re-pinning would be churn.
    func testNoiseInEitherDirectionDoesNotRepin() {
        XCTAssertFalse(ChatScrollManager.shouldRepinForHeightChange(
            previousHeight: 3952, currentHeight: 3952 - (ChatScrollManager.heightRepinThreshold - 1),
            autoScrollOn: true, isOpening: false
        ))
        XCTAssertFalse(ChatScrollManager.shouldRepinForHeightChange(
            previousHeight: 3952, currentHeight: 3952 + (ChatScrollManager.heightRepinThreshold - 1),
            autoScrollOn: true, isOpening: false
        ))
    }

    /// The first measurement is not a change.
    func testFirstMeasurementIsNotAShrink() {
        XCTAssertFalse(
            ChatScrollManager.shouldRepinForHeightChange(
                previousHeight: 0, currentHeight: 3952, autoScrollOn: true, isOpening: false
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
                lastMessageVisible: false, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    func testLastMessageVisibleNeedsNoRecovery() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// A person who scrolled up has auto-scroll off, and the last message being off screen is
    /// exactly what they asked for.
    func testReadingUpTheTranscriptIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, autoScrollOn: false, isOpening: false, searchActive: false
            ),
            "recovering here would yank a reader back to the bottom on every scroll"
        )
    }

    /// During the opening the offset has not landed and the corrective pin series owns the window;
    /// a second source of pins there would fight it.
    func testOpeningWindowOwnsItsOwnCorrection() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, autoScrollOn: true, isOpening: true, searchActive: false
            )
        )
    }

    /// Search deliberately puts the transcript somewhere other than the end.
    func testSearchIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, autoScrollOn: true, isOpening: false, searchActive: true
            )
        )
    }

    /// The manager starts believing the newest message is on screen, so an empty or not-yet-drawn
    /// transcript never reads as stranded.
    func testManagerStartsNotStranded() {
        XCTAssertTrue(ChatScrollManager().isLastMessageVisible)
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

    /// The regression, stated as the property that caused it: no immediate tick. With a leading
    /// zero every measurement in a burst scrolls; without one, successive changes cancel each
    /// other and a burst costs a single scroll.
    func testHeightChangeDoesNotScrollImmediately() {
        XCTAssertFalse(
            ChatScrollManager.heightSettleDelaysMs.contains(0),
            "a leading 0 tick makes every intermediate layout measurement a visible jump"
        )
    }

    /// The series must still land, and land twice — one pin after the settle, one after the layout
    /// pass that the settle itself can trigger.
    func testHeightChangeStillPins() {
        XCTAssertEqual(ChatScrollManager.heightSettleDelaysMs.count, 2)
        XCTAssertTrue(ChatScrollManager.heightSettleDelaysMs.allSatisfy { $0 > 0 })
        XCTAssertEqual(ChatScrollManager.heightSettleDelaysMs.first, ChatScrollManager.heightSettleMs)
    }

    /// Long enough to swallow a layout pass, short enough not to read as lag. Pinned as a range so
    /// the number is a decision rather than a habit.
    func testSettleDelayIsWithinAReasonableBand() {
        XCTAssertGreaterThanOrEqual(ChatScrollManager.heightSettleMs, 60)
        XCTAssertLessThanOrEqual(ChatScrollManager.heightSettleMs, 150)
    }

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
}
