//
//  NotificationEmptyContentTests.swift
//  ConstructMessengerTests
//
//  The notification extension handed iOS empty content for a delivery receipt in Debug and Beta
//  (a trial, 2026-10-16), and iOS 27 presented it: testers got notifications "with no message
//  at all" (2026-10-19). Empty content hides a banner only with Apple's filtering entitlement,
//  so it is handed back only for `AlertPresentation.dropped`, which `AlertPresentation.of` gives
//  only under `filtersAlerts` (AlertDecisionTests; todo 124, #512). The extension is not in the
//  test target; the guard is on the source.
//

import XCTest

final class NotificationEmptyContentTests: XCTestCase {

    /// Mutation: hand back `UNNotificationContent()` on the passive or as-is path, or switch on
    /// anything but the entitlement-aware presentation — this reddens.
    func testEmptyContentOnlyWhenEntitledToFilter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lines = try String(
            contentsOf: root.appendingPathComponent("ConstructNotifications/NotificationService.swift"),
            encoding: .utf8
        ).components(separatedBy: "\n")
        XCTAssertTrue(
            lines.contains { $0.contains("switch AlertPresentation.of(decision, filtersAlerts: Self.filtersAlerts)") },
            "the presentation is decided with the entitlement"
        )
        let empties = lines.indices.filter { lines[$0].contains("handler(UNNotificationContent())") }
        XCTAssertEqual(empties.count, 1, "one empty-content path, the entitled one")
        for i in empties {
            let caseLine = lines[..<i].last { $0.contains("case ") } ?? ""
            XCTAssertTrue(caseLine.contains("case .dropped:"), "empty content without the entitlement is shown by iOS 27")
        }
    }
}
