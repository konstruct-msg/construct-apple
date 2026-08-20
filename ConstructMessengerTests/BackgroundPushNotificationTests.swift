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
//   2. `activeChatId` is cleared only when the chat screen disappears — backgrounding the app
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
            InAppNotificationService.isChatVisible("chat-1", activeChatId: "chat-1", appIsActive: false),
            "an open chat behind a backgrounded app must not suppress the banner — " +
            "activeChatId is not cleared on background"
        )
    }

    func testIsChatVisible_OpenChatInForeground_IsVisible() {
        XCTAssertTrue(
            InAppNotificationService.isChatVisible("chat-1", activeChatId: "chat-1", appIsActive: true)
        )
    }

    func testIsChatVisible_OtherChat_IsNeverVisible() {
        XCTAssertFalse(
            InAppNotificationService.isChatVisible("chat-1", activeChatId: "chat-2", appIsActive: true)
        )
        XCTAssertFalse(
            InAppNotificationService.isChatVisible("chat-1", activeChatId: nil, appIsActive: true)
        )
    }
}
