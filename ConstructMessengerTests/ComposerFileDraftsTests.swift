//
//  ComposerFileDraftsTests.swift
//  ConstructMessengerTests
//
//  "Send logs to a chat" hands the archive to one chat's composer, once.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ComposerFileDraftsTests: XCTestCase {
    private let archive = URL(fileURLWithPath: "/tmp/construct-logs-1.txt")

    func testTheFileGoesToThePickedChatOnly() {
        let drafts = ComposerFileDrafts()
        drafts.hand([archive], to: "chat-a")
        XCTAssertEqual(drafts.take(for: "chat-b"), [])
        XCTAssertEqual(drafts.take(for: "chat-a"), [archive])
    }

    func testTakingEmptiesTheDraftSoTheFileIsNotAddedTwice() {
        let drafts = ComposerFileDrafts()
        drafts.hand([archive], to: "chat-a")
        _ = drafts.take(for: "chat-a")
        XCTAssertEqual(drafts.take(for: "chat-a"), [])
        XCTAssertNil(drafts.pending["chat-a"])
    }

    func testAHandOffBeforeTheChatOpensKeepsBothFiles() {
        let drafts = ComposerFileDrafts()
        let second = URL(fileURLWithPath: "/tmp/construct-logs-2.txt")
        drafts.hand([archive], to: "chat-a")
        drafts.hand([second], to: "chat-a")
        XCTAssertEqual(drafts.take(for: "chat-a"), [archive, second])
    }

    func testNothingHandedLeavesNoDraftThatWouldWakeTheChat() {
        let drafts = ComposerFileDrafts()
        drafts.hand([], to: "chat-a")
        XCTAssertNil(drafts.pending["chat-a"])
    }
}
