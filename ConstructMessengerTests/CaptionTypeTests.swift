//
//  CaptionTypeTests.swift
//  ConstructMessengerTests
//
//  A caption under a photo, video or file is message text the sender wrote, and it was set at
//  12 pt — in the chrome face for files and uploads — beside 15 pt bubbles (owner, 2026-10-19).
//

import XCTest

final class CaptionTypeTests: XCTestCase {

    /// Mutation: set any caption back to `captionSize` — this reddens.
    func testCaptionsAreSetAsMessageText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["MediaMessageView.swift", "FileAttachmentBubbleView.swift"] {
            let text = try String(
                contentsOf: root.appendingPathComponent("ConstructMessenger/Views/Chat/\(file)"),
                encoding: .utf8
            )
            XCTAssertFalse(text.contains("Typography.captionSize"), "\(file): a caption is message text")
            XCTAssertTrue(text.contains("CTFont.message(ChatUIConstants.Typography.messageTextSize)"), file)
        }
    }
}
