//
//  DeviceLinkScanTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

/// What a scanned link code does. How it is written and read is the core's (`device_link_qr`).
@MainActor
final class DeviceLinkScanTests: XCTestCase {

    private let identity = Data(repeating: 5, count: 32)
    private let hybrid = Data(repeating: 6, count: 64)

    func testAJoinRequestAsksThePersonWithWhatTheCodeSays() async throws {
        let code = try deviceJoinRequestQr(
            identityPublic: identity, hybridPublic: hybrid, name: "Mac & iPad", platform: "desktop"
        )
        let vm = DeviceLinkViewModel()
        await vm.scanAndLink(scannedURL: code)
        let pending = try XCTUnwrap(vm.pendingApproval)
        XCTAssertEqual(pending.deviceId, deriveDeviceId(identityPublicKey: identity))
        XCTAssertEqual(pending.identityPublic, identity)
        XCTAssertEqual(pending.fingerprint, historyQrFingerprint(identityPublic: identity, hybridPublic: hybrid))
        XCTAssertEqual(pending.deviceName, "Mac & iPad")
        XCTAssertNil(vm.errorMessage)
    }

    func testAnotherCodeIsRefused() async {
        let vm = DeviceLinkViewModel()
        await vm.scanAndLink(scannedURL: "konstruct://add?invite=x")
        XCTAssertNil(vm.pendingApproval)
        XCTAssertNotNil(vm.errorMessage)
    }
}
