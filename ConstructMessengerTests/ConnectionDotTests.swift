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

    /// The tab roots' titles have no connection subtitle: it came and went with the connection and
    /// moved the title each time (owner, 2026-10-19).
    /// Mutation: a `.navigationSubtitle(` on any screen — this reddens.
    func testNoTitleHasASubtitleThatComesAndGoes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for dir in ["ConstructMessenger", "Construct Desktop"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                if try String(contentsOf: url, encoding: .utf8).contains(".navigationSubtitle(") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found the sources")
        XCTAssertEqual(offenders, [])
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
