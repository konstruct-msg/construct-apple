//
//  RegistrationResumeTests.swift
//  ConstructMessengerTests
//
//  Registration saves the device keys before its first RPC, so a lost response can be retried
//  with the same identity. The screen's guard read "keys present" as "registered", and every
//  retry after a failure stayed on "generating keys" forever (2026-09-29, TestFlight 694).
//

import XCTest
@testable import Construct_Messenger

final class RegistrationResumeTests: XCTestCase {

    /// The incident: keys saved, the server never answered — the retry must run.
    func testKeysWithoutAUserIdAreRetried() {
        XCTAssertTrue(RegistrationFlowView.shouldRegister(hasKeys: true, hasUserId: false))
    }

    func testAFreshDeviceRegisters() {
        XCTAssertTrue(RegistrationFlowView.shouldRegister(hasKeys: false, hasUserId: false))
    }

    /// The case the guard exists for: the view recreated while dismissing a finished registration.
    func testAFinishedRegistrationDoesNotRunAgain() {
        XCTAssertFalse(RegistrationFlowView.shouldRegister(hasKeys: true, hasUserId: true))
    }
}
