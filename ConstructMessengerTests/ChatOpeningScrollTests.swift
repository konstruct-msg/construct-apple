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
}
