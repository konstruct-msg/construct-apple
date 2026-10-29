//
//  DeviceLinkJoinRequestGateTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

/// A join request deletes the device's keys. On a signed-in device that deletes the keys its
/// account was just given (tester log 2026-10-29: the Mac linked, then made a second device).
final class DeviceLinkJoinRequestGateTests: XCTestCase {

    func testADeviceWithNoAccountMayAskToJoin() {
        XCTAssertTrue(DeviceLinkViewModel.joinRequestMayStart(isAuthenticated: false))
    }

    func testASignedInDeviceNeverStartsAJoinRequest() {
        XCTAssertFalse(DeviceLinkViewModel.joinRequestMayStart(isAuthenticated: true))
    }
}
