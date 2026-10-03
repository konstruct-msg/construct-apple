//
//  ChatsSplitSeamSwipeTests.swift
//  ConstructMessengerTests
//
//  The iPad chats list hides and shows with a swipe on the seam between the list and the
//  chat (2026-10-03). The seam is the only place for it: leftward on a row deletes the chat,
//  leftward on a bubble replies.
//

import XCTest
@testable import Construct_Messenger

final class ChatsSplitSeamSwipeTests: XCTestCase {
    private let commit: CGFloat = 60

    func testLeftwardSwipeHidesTheList() {
        XCTAssertEqual(ChatsSplitView.seamSwipeCollapses(translation: CGSize(width: -80, height: 5), commit: commit), true)
    }

    func testRightwardSwipeShowsTheList() {
        XCTAssertEqual(ChatsSplitView.seamSwipeCollapses(translation: CGSize(width: 80, height: -5), commit: commit), false)
    }

    /// A short drag is not a request either way.
    func testShortDragDoesNothing() {
        XCTAssertNil(ChatsSplitView.seamSwipeCollapses(translation: CGSize(width: -40, height: 0), commit: commit))
    }

    /// A mostly vertical drag on the seam is a scroll, not a swipe.
    func testVerticalDragDoesNothing() {
        XCTAssertNil(ChatsSplitView.seamSwipeCollapses(translation: CGSize(width: -70, height: 90), commit: commit))
    }
}
