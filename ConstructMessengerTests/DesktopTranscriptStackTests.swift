//
//  DesktopTranscriptStackTests.swift
//  Construct MessengerTests
//
//  Desktop's transcript is an eager stack (decisions/chat-viewport-owned-inset.md, Desktop step
//  taken 2026-11-12). The tests run on the iOS simulator and cannot lay out the Desktop window, so
//  the choice is pinned where it is made: the Desktop source.
//

import XCTest

final class DesktopTranscriptStackTests: XCTestCase {

    private func desktopChatSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Construct Desktop/Views/DesktopChatView.swift"),
            encoding: .utf8
        )
    }

    /// The lazy stack hung the Desktop window at 100 % CPU: a chat that almost fit, its content
    /// height cycling 605 → 584 → 567 pt inside one layout pass (TRANSCRIPT_LAYOUT_LOOP,
    /// stack=lazy). Going back to it is a new decision, not an edit.
    ///
    /// Mutation: `usesEagerStack: false`, or drop the argument (the container defaults to lazy) —
    /// this reddens.
    func testTheDesktopTranscriptIsAnEagerStack() throws {
        XCTAssertTrue(try desktopChatSource().contains("usesEagerStack: true"))
    }

    /// In an eager stack a row's onAppear/onDisappear mean built/removed, not on/off screen, so a
    /// last-row visibility report from them would tell the scroll manager the tail is hidden when
    /// a message is deleted, and arm a recovery for an unmount that cannot happen.
    ///
    /// Mutation: restore the report — this reddens.
    func testNoRowVisibilityIsReportedFromAnEagerStack() throws {
        XCTAssertFalse(try desktopChatSource().contains("scrollManager.noteLastMessageVisible("))
    }
}
