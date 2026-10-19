//
//  IncomingAttentionTests.swift
//  ConstructMessengerTests
//
//  A message already read on another device of ours skipped the unread count but still raised a
//  banner: writing on the Desktop, the phone kept ringing for the replies (owner, 2026-10-19).
//

import XCTest
@testable import Construct_Messenger

final class IncomingAttentionTests: XCTestCase {

    /// Mutation: let `notifies` ignore `readElsewhere` — this reddens.
    func testReadOnAnotherDeviceIsNeitherCountedNorAnnounced() {
        XCTAssertEqual(
            IncomingAttention.decide(chatVisible: false, readElsewhere: true),
            .init(countsAsUnread: false, notifies: false)
        )
    }

    func testAnUnreadMessageInAClosedChatIsBoth() {
        XCTAssertEqual(
            IncomingAttention.decide(chatVisible: false, readElsewhere: false),
            .init(countsAsUnread: true, notifies: true)
        )
    }

    /// The open chat is not counted; its banner is the banner path's own visibility test.
    func testAnOpenChatIsNotCounted() {
        XCTAssertFalse(IncomingAttention.decide(chatVisible: true, readElsewhere: false).countsAsUnread)
    }

    func testTheChatBannerHasOneIdentifier() {
        XCTAssertEqual(LocalNotificationManager.chatBannerId("abc"), "msg-chat-abc")
    }
}
