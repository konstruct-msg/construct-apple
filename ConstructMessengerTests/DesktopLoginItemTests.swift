//
//  DesktopLoginItemTests.swift
//  ConstructMessengerTests
//
//  "Open at login" on Desktop reads the system's state. A login item that is registered but not
//  allowed in System Settings will not run: the row must say so, or the user believes Konstruct
//  will be there after a restart and misses every message until they open it.
//

import XCTest
@testable import Construct_Messenger

final class DesktopLoginItemTests: XCTestCase {

    func testEnabledIsOnWithNothingToApprove() {
        XCTAssertEqual(DesktopLoginItem.row(for: .enabled), .init(isOn: true, needsApproval: false))
    }

    /// Mutation: `requiresApproval` → `needsApproval: false` — this reddens.
    func testRegisteredButNotAllowedAsksForApproval() {
        XCTAssertEqual(DesktopLoginItem.row(for: .requiresApproval), .init(isOn: true, needsApproval: true))
    }

    func testNotRegisteredOrNotFoundIsOff() {
        XCTAssertEqual(DesktopLoginItem.row(for: .notRegistered), .init(isOn: false, needsApproval: false))
        XCTAssertEqual(DesktopLoginItem.row(for: .notFound), .init(isOn: false, needsApproval: false))
    }
}
