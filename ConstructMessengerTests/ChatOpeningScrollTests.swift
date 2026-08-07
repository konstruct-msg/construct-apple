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






    // MARK: - Auto-scroll must keep the promise it makes

    /// The second half of the defect, and the one a distance threshold cannot express: auto-scroll
    /// claims the newest message is on screen, and `distance <= threshold` accepted −922 exactly as
    /// readily as 0. Stated as visibility because an inset chat is legitimately negative and any
    /// numeric cutoff between "composer inset" and "stranded" would move with the composer.
    func testPinnedButLastMessageOffScreenRecovers() {
        XCTAssertTrue(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    func testLastMessageVisibleNeedsNoRecovery() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01, autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// A person who scrolled up has auto-scroll off, and the last message being off screen is
    /// exactly what they asked for.
    func testReadingUpTheTranscriptIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, autoScrollOn: false, isOpening: false, searchActive: false
            ),
            "recovering here would yank a reader back to the bottom on every scroll"
        )
    }

    /// During the opening the offset has not landed and the corrective pin series owns the window;
    /// a second source of pins there would fight it.
    func testOpeningWindowOwnsItsOwnCorrection() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, autoScrollOn: true, isOpening: true, searchActive: false
            )
        )
    }

    /// Search deliberately puts the transcript somewhere other than the end.
    func testSearchIsNotRecovered() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: 0.01, autoScrollOn: true, isOpening: false, searchActive: true
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
                lastMessageVisible: false, newestHiddenFor: 4, visibleContentFraction: fraction,
                autoScrollOn: true, isOpening: false, searchActive: false
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
                lastMessageVisible: false, newestHiddenFor: 0.1, visibleContentFraction: fraction,
                autoScrollOn: true, isOpening: false, searchActive: false
            ),
            "a flicker cannot sustain an absence; 112 of 585's 120 episodes were under a second"
        )
    }

    func testAbsenceMustOutlastTheGraceExactly() {
        let grace = ChatScrollManager.newestMessageAbsenceGrace
        func stranded(after seconds: TimeInterval) -> Bool {
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: false, newestHiddenFor: seconds, visibleContentFraction: 0.9,
                autoScrollOn: true, isOpening: false, searchActive: false
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
                lastMessageVisible: false, newestHiddenFor: 0, visibleContentFraction: 0.01,
                autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// …but never over a visible newest row. A short transcript covers little of the viewport and
    /// is perfectly healthy; coverage says where the viewport is, not whether anything is drawn.
    func testCoverageNeverOverridesAVisibleNewestRow() {
        XCTAssertFalse(
            ChatScrollManager.shouldRecoverStrandedViewport(
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01,
                autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }

    /// Neither route may override the guards. A reader who scrolled up asked for exactly this.
    func testAPersistentAbsenceStillRespectsTheGuards() {
        for (auto, opening, search) in [(false, false, false), (true, true, false), (true, false, true)] {
            XCTAssertFalse(
                ChatScrollManager.shouldRecoverStrandedViewport(
                    lastMessageVisible: false, newestHiddenFor: 30, visibleContentFraction: 0.01,
                    autoScrollOn: auto, isOpening: opening, searchActive: search
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
                lastMessageVisible: false, newestHiddenFor: 2, visibleContentFraction: fraction,
                autoScrollOn: true, isOpening: false, searchActive: false
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
                lastMessageVisible: false, newestHiddenFor: 0.1, visibleContentFraction: fraction,
                autoScrollOn: true, isOpening: false, searchActive: false
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
                lastMessageVisible: true, newestHiddenFor: 0, visibleContentFraction: 0.01,
                autoScrollOn: true, isOpening: false, searchActive: false
            )
        )
    }
}
