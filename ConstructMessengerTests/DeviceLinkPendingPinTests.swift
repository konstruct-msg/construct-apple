//
//  DeviceLinkPendingPinTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class DeviceLinkPendingPinTests: XCTestCase {

    private let token = "pin-test-token"
    private let userId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    override func tearDown() {
        DeviceLinkPendingPin.clear(forToken: token)
        DeviceLinkPendingPin.clear(forUserId: userId)
        super.tearDown()
    }

    func testStoreLoadAndBindToAccount() {
        let fp = Data((0..<32).map { UInt8($0) })
        DeviceLinkPendingPin.store(fp, forToken: token)
        XCTAssertEqual(DeviceLinkPendingPin.load(forToken: token), fp)

        DeviceLinkPendingPin.bindToAccount(userId: userId, fromToken: token)
        XCTAssertNil(DeviceLinkPendingPin.load(forToken: token))
        XCTAssertEqual(DeviceLinkPendingPin.load(forUserId: userId), fp)

        DeviceLinkPendingPin.clear(forUserId: userId)
        XCTAssertNil(DeviceLinkPendingPin.load(forUserId: userId))
    }

    func testExtractFpFromLinkURL() {
        let fp = String(repeating: "ab", count: 32)
        let url = "konstruct://link?token=tok&fp=\(fp)"
        let data = DeviceLinkViewModel.extractFp(from: url)
        XCTAssertEqual(data?.count, 32)
        XCTAssertEqual(data?.first, 0xAB)
        XCTAssertNil(DeviceLinkViewModel.extractFp(from: "konstruct://link?token=tok"))
        XCTAssertNil(DeviceLinkViewModel.extractFp(from: "konstruct://link?token=tok&fp=zz"))
    }

    func testTransferSourcesDoNotCallGetSigningKeyBytes() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Transfer")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                text.contains("getSigningKeyBytes"),
                "\(url.lastPathComponent) must not export the signing secret"
            )
        }
    }
}
