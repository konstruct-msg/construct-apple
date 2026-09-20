//
//  ChatListNavigationTests.swift
//  Construct DesktopTests
//
//  ⌥⌘↓ / ⌥⌘↑ / ⌘1…9 were dead: DesktopRootView posted three notifications and nothing in the
//  app observed them. The arithmetic that answers them now lives apart from the view so its
//  decisions — what happens at the ends, with nothing open, with a search box hiding the open
//  chat — are written down as expectations rather than as whatever the code happened to do.
//

import XCTest
@testable import Construct_Desktop

final class ChatListNavigationTests: XCTestCase {

    private let list = ["alice", "bob", "carol"]

    // MARK: - Moving

    func testNextAndPreviousMoveOneRowInTheDisplayedOrder() {
        XCTAssertEqual(ChatListNavigation.step(from: "alice", by: 1, in: list), "bob")
        XCTAssertEqual(ChatListNavigation.step(from: "carol", by: -1, in: list), "bob")
    }

    /// With nothing open, the shortcut should show a chat rather than do nothing — an empty detail
    /// pane is the state a user is most likely to press it in.
    func testWithNothingOpenEachDirectionOpensItsEndOfTheList() {
        XCTAssertEqual(ChatListNavigation.step(from: nil, by: 1, in: list), "alice")
        XCTAssertEqual(ChatListNavigation.step(from: nil, by: -1, in: list), "carol")
    }

    /// The ends deliberately do not wrap: on a long list a silent jump from last to first reads as
    /// a misfire, and ⌘1 already means "go to the top".
    func testTheEndsDoNotWrap() {
        XCTAssertNil(ChatListNavigation.step(from: "carol", by: 1, in: list))
        XCTAssertNil(ChatListNavigation.step(from: "alice", by: -1, in: list))
    }

    /// Search hides rows. The chat still open may not be among them, and the keys must keep working
    /// on what is actually on screen instead of refusing to move.
    func testAnOpenChatFilteredOutBySearchFallsBackToTheVisibleEnd() {
        let filtered = ["bob", "carol"]

        XCTAssertEqual(ChatListNavigation.step(from: "alice", by: 1, in: filtered), "bob")
        XCTAssertEqual(ChatListNavigation.step(from: "alice", by: -1, in: filtered), "carol")
    }

    func testAnEmptyListNeverMoves() {
        XCTAssertNil(ChatListNavigation.step(from: nil, by: 1, in: []))
        XCTAssertNil(ChatListNavigation.step(from: "alice", by: -1, in: []))
    }

    /// One chat is a list with no neighbours in either direction, but it is still what "next" opens
    /// when nothing is open.
    func testASingleChatIsOpenableButHasNoNeighbours() {
        XCTAssertEqual(ChatListNavigation.step(from: nil, by: 1, in: ["alice"]), "alice")
        XCTAssertNil(ChatListNavigation.step(from: "alice", by: 1, in: ["alice"]))
        XCTAssertNil(ChatListNavigation.step(from: "alice", by: -1, in: ["alice"]))
    }

    // MARK: - Jumping

    func testJumpTakesTheNthVisibleChat() {
        XCTAssertEqual(ChatListNavigation.jump(to: 0, in: list), "alice")
        XCTAssertEqual(ChatListNavigation.jump(to: 2, in: list), "carol")
    }

    /// ⌘7 on a three-chat list: nothing, rather than the last one. Clamping would make two
    /// different shortcuts do the same thing and hide the fact that there is no seventh chat.
    func testJumpPastTheEndDoesNothing() {
        XCTAssertNil(ChatListNavigation.jump(to: 6, in: list))
        XCTAssertNil(ChatListNavigation.jump(to: 0, in: []))
    }

    /// The menu passes `n - 1`, so a negative index is only reachable through a bug — it must not
    /// trap on the negative-index subscript.
    func testANegativeIndexIsRefusedRatherThanCrashing() {
        XCTAssertNil(ChatListNavigation.jump(to: -1, in: list))
    }
}
