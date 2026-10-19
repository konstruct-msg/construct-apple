//
//  NotificationEmptyContentTests.swift
//  ConstructMessengerTests
//
//  The notification extension handed iOS empty content for a delivery receipt in Debug and Beta
//  (a trial, 2026-10-16), and iOS 27 presented it: testers got notifications "with no message
//  at all" (2026-10-19). Empty content hides a banner only with Apple's filtering entitlement,
//  so it is handed back only under `filtersAlerts`. The extension is not in the test target;
//  the guard is on the source.
//

import XCTest

final class NotificationEmptyContentTests: XCTestCase {

    /// Mutation: hand back `UNNotificationContent()` on the not-entitled path — this reddens.
    func testEmptyContentOnlyWhenEntitledToFilter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lines = try String(
            contentsOf: root.appendingPathComponent("ConstructNotifications/NotificationService.swift"),
            encoding: .utf8
        ).components(separatedBy: "\n")
        let empties = lines.indices.filter { lines[$0].contains("handler(UNNotificationContent())") }
        XCTAssertEqual(empties.count, 1, "one empty-content path, the entitled one")
        for i in empties {
            let caseLine = lines[..<i].last { $0.contains("case ") } ?? ""
            XCTAssertTrue(caseLine.contains("where Self.filtersAlerts"), "empty content without the entitlement is shown by iOS 27")
        }
    }
}
