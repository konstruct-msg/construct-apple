//
//  BackgroundPushNotificationTests.swift
//  ConstructMessengerTests
//
//  Two independent halves of "no push notification while backgrounded", both observed on
//  device 2026-07-31 with a healthy server and healthy APNs delivery:
//
//   1. BackgroundFetchManager read `message.from` without opening the SealedInner, so every
//      stealth-delivered message was "unknown sender" and no notification was ever posted.
//      That half is now covered by SealedRoutingBoundaryTests instead: the background path was
//      folded into MessageRouter, so there is only one unseal boundary left to test.
//   2. The open chat (`ChatOnScreen`) is cleared only when the chat screen disappears — backgrounding the app
//      with a chat open left it set, so InAppNotificationService suppressed every banner for
//      that conversation (and MessageRouter kept `unreadCount` at 0) for the whole background
//      period.
//
//  See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
//

import XCTest
@testable import Construct_Messenger

final class BackgroundPushNotificationTests: XCTestCase {

    // MARK: - 2. Banner suppression must require the app to be on screen

    /// The regression: chat open + app backgrounded is NOT visible. Under XCTest the live
    /// applicationState is always `.active`, so this branch is only reachable through the
    /// pure overload — which is why it exists.
    func testIsChatVisible_OpenChatButBackgrounded_IsNotVisible() {
        XCTAssertFalse(
            InAppNotificationService.isChatVisible("chat-1", chatOnScreen: "chat-1", appIsActive: false),
            "an open chat behind a backgrounded app must not suppress the banner — " +
            "the open chat is not cleared on background"
        )
    }

    func testIsChatVisible_OpenChatInForeground_IsVisible() {
        XCTAssertTrue(
            InAppNotificationService.isChatVisible("chat-1", chatOnScreen: "chat-1", appIsActive: true)
        )
    }

    func testIsChatVisible_OtherChat_IsNeverVisible() {
        XCTAssertFalse(
            InAppNotificationService.isChatVisible("chat-1", chatOnScreen: "chat-2", appIsActive: true)
        )
        XCTAssertFalse(
            InAppNotificationService.isChatVisible("chat-1", chatOnScreen: nil, appIsActive: true)
        )
    }

    // MARK: - The open chat is the screen's (todo 288)

    /// A chat whose screen has gone is not visible, whatever still holds its view model. Until
    /// 2026-11-09 the open chat was a second carrier, registered by `ChatViewModel` on its first
    /// appear and cleared only in its `deinit`: a message after leaving the chat was neither
    /// counted unread nor announced (stand 2026-11-09, `unread 0 → 0` 18 s after leaving).
    ///
    /// Mutations that redden it: pass anything but `ChatOnScreen.shared.chatId` from
    /// `isChatVisible(_:)`; make `ChatOnScreen.disappeared` keep the chat.
    @MainActor
    func testTheOpenChatIsTheOneOnScreen() {
        let before = ChatOnScreen.shared.chatId
        defer {
            ChatOnScreen.shared.disappeared("chat-288")
            if let before { ChatOnScreen.shared.appeared(before) }
        }
        ChatOnScreen.shared.appeared("chat-288")
        XCTAssertTrue(InAppNotificationService.isChatVisible("chat-288", appIsActive: true), "the chat on screen is visible")

        ChatOnScreen.shared.disappeared("chat-288")
        XCTAssertFalse(InAppNotificationService.isChatVisible("chat-288", appIsActive: true), "a chat left is not visible")
    }
}
