//
//  MacOnScreenTests.swift
//  ConstructMessengerTests
//
//  On a Mac the open chat counted as seen even with its window minimised or behind another app,
//  so a message there made no banner (2026-10-29). `MacOnScreen` is the rule that replaced the
//  hard-coded `true`.
//

import XCTest
@testable import Construct_Messenger

final class MacOnScreenTests: XCTestCase {

    private func window(main: Bool = true, visible: Bool = true, minimised: Bool = false,
                        unoccluded: Bool = true) -> MacOnScreen.Window {
        .init(canBecomeMain: main, isVisible: visible, isMiniaturized: minimised, isUnoccluded: unoccluded)
    }

    func testFrontmostWithAShownWindowIsOnScreen() {
        XCTAssertTrue(MacOnScreen.isOnScreen(appIsActive: true, windows: [window()]))
    }

    /// Another app in front: the user cannot see the chat.
    /// Mutation: drop `appIsActive &&` — this reddens.
    func testAnotherAppInFrontIsNotOnScreen() {
        XCTAssertFalse(MacOnScreen.isOnScreen(appIsActive: false, windows: [window()]))
    }

    /// Frontmost but every window minimised to the Dock, or covered.
    /// Mutation: drop `!$0.isMiniaturized` — this reddens.
    func testMinimisedOrCoveredWindowsAreNotOnScreen() {
        XCTAssertFalse(MacOnScreen.isOnScreen(appIsActive: true, windows: [window(minimised: true)]))
        XCTAssertFalse(MacOnScreen.isOnScreen(appIsActive: true, windows: [window(unoccluded: false)]))
        XCTAssertFalse(MacOnScreen.isOnScreen(appIsActive: true, windows: []))
    }

    /// A panel that cannot become main (a popover, the ringer) does not show a chat.
    func testAPanelAloneIsNotOnScreen() {
        XCTAssertFalse(MacOnScreen.isOnScreen(appIsActive: true, windows: [window(main: false)]))
        XCTAssertTrue(MacOnScreen.isOnScreen(appIsActive: true,
                                             windows: [window(main: false), window(minimised: true), window()]))
    }

    /// The banner decision with the Mac's answer: the open chat makes a banner once it is hidden.
    func testTheOpenChatGetsABannerWhenTheWindowIsMinimised() {
        let onScreen = MacOnScreen.isOnScreen(appIsActive: true, windows: [window(minimised: true)])
        XCTAssertFalse(InAppNotificationService.isChatVisible("chat-1", activeChatId: "chat-1", appIsActive: onScreen))
    }

    /// Hidden → shown marks the open chat read; staying shown or going away does not.
    /// Mutation: return `isOnScreen` alone — the second assertion reddens.
    func testTheOpenChatIsReadWhenItComesBack() {
        XCTAssertTrue(MacOnScreen.cameBack(wasOnScreen: false, isOnScreen: true))
        XCTAssertFalse(MacOnScreen.cameBack(wasOnScreen: true, isOnScreen: true))
        XCTAssertFalse(MacOnScreen.cameBack(wasOnScreen: true, isOnScreen: false))
        XCTAssertFalse(MacOnScreen.cameBack(wasOnScreen: false, isOnScreen: false))
    }
}
