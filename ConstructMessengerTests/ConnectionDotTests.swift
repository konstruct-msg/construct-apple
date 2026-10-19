//
//  ConnectionDotTests.swift
//  ConstructMessengerTests
//
//  The chats list's connection dot went with the floating header on 2026-10-08 and was missed:
//  the subtitle that replaced it says nothing while connected, so "everything works" had no sign
//  (owner, 2026-10-19). The guard is on the source — the bar item is not reachable from a test.
//

import XCTest

final class ConnectionDotTests: XCTestCase {

    /// Mutation: drop the `ConnectionStatusIndicator()` toolbar item from `ChatsListView` — this reddens.
    func testTheChatsListShowsTheConnectionDot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("ConstructMessenger/Views/Chats/ChatsListView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("ConnectionStatusIndicator()"), "the chats list bar carries the connection dot")
    }

    /// Mutation: put `.connectionSubtitle()` back on the chats list — this reddens.
    func testTheChatsTitleHasNoConnectionSubtitle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("ConstructMessenger/Views/Chats/ChatsListView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(".connectionSubtitle()"), "a subtitle that comes and goes moves the title")
    }

    /// Mutation: give the dot its own leading bar item again (a glass capsule) — this reddens.
    func testTheDotSitsBesideTheTitle() throws {
        let source = try Self.source("ConstructMessenger/Views/Chats/ChatsListView.swift")
        XCTAssertFalse(source.contains("placement: .topBarLeading"), "the dot is the title's neighbour, not a bar item")
        XCTAssertTrue(source.contains("placement: .principal"), "the title is a view carrying the dot")
    }

    /// Mutation: bring back the `repeatForever` pulse while connecting — this reddens.
    func testTheDotDoesNotPulse() throws {
        let source = try Self.source("ConstructMessenger/Views/Components/ConnectionStatusIndicator.swift")
        XCTAssertFalse(source.contains("repeatForever"), "beside the title a pulsing dot rocks the title")
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
