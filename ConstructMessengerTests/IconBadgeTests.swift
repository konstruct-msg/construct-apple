//
//  IconBadgeTests.swift
//  ConstructMessengerTests
//
//  The icon badge never rose above zero: nothing set it, the server's push carries none, and
//  every foreground and opened chat cleared it — testers could not tell from the icon whether
//  anything was waiting (2026-10-19). It is the unread count now, set in one place.
//

import XCTest
@testable import Construct_Messenger

final class IconBadgeTests: XCTestCase {

    /// Mutation: return 0 from `BadgeCount.total` (the old badge) — this reddens.
    func testTheBadgeIsTheUnreadTotal() {
        XCTAssertEqual(BadgeCount.total([2, 0, 3]), 5)
        XCTAssertEqual(BadgeCount.total([]), 0)
        XCTAssertEqual(BadgeCount.total([-1, 2]), 2, "a negative count is a store defect, not fewer unread")
    }

    /// Mutation: put a `setBadgeCount(0)` back on the foreground path — this reddens.
    func testNothingZeroesTheBadge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let zeroing = try NSRegularExpression(pattern: #"setBadgeCount\(0\)|applicationIconBadgeNumber\s*=\s*0"#)
        var offenders: [String] = []
        var scanned = 0
        for dir in ["ConstructMessenger", "Construct Desktop", "ConstructNotifications"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                if zeroing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found the sources")
        XCTAssertEqual(offenders, [], "the badge is LocalNotificationManager.syncBadge(), the unread count")
    }
}
