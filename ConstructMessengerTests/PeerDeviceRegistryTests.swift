//
//  PeerDeviceRegistryTests.swift
//  ConstructMessengerTests
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class PeerDeviceRegistryTests: XCTestCase {

    private let peer = "e7a4e3d2-0000-4000-8000-000000000001"

    override func setUp() async throws {
        PeerDeviceRegistry.shared.clear()
    }

    private func bundle(_ deviceId: String) -> DeviceBundleData {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return DeviceBundleData(
            deviceId: deviceId,
            bundle: PublicKeyBundleData(
                userId: peer, username: "",
                identityPublic: key.publicKey.rawRepresentation,
                signedPrekeyPublic: Data(repeating: 0, count: 32),
                signature: Data(repeating: 0, count: 64),
                verifyingKey: Data(repeating: 0, count: 32),
                suiteId: 1, spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0
            ),
            platform: .ios
        )
    }

    func testWhatWasRecordedComesBack() {
        PeerDeviceRegistry.shared.record(userId: peer, devices: [bundle("d1"), bundle("d2")])
        XCTAssertEqual(PeerDeviceRegistry.shared.knownDevices(of: peer).map(\.deviceId), ["d1", "d2"])
        XCTAssertEqual(PeerDeviceRegistry.shared.identityKeys(of: peer).count, 2)
    }

    /// An unknown account reads as "we do not know", never as "it has none" — and every consumer
    /// must treat the two the same way, because an empty answer is what a miss looks like.
    func testAnUnknownAccountIsEmpty() {
        XCTAssertTrue(PeerDeviceRegistry.shared.knownDevices(of: peer).isEmpty)
    }

    /// The server returns nothing for an account whose devices are momentarily unreadable as well
    /// as for one with none. Recording that would turn a transient failure into an hour of
    /// confidently knowing the account has no devices — and the consumer that concludes "foreign"
    /// from a complete set would then discard real messages.
    ///
    /// Mutation: drop the `!devices.isEmpty` guard — this reddens.
    func testAnEmptyAnswerIsNotRecordedOverWhatWeKnew() {
        PeerDeviceRegistry.shared.record(userId: peer, devices: [bundle("d1")])
        PeerDeviceRegistry.shared.record(userId: peer, devices: [])
        XCTAssertEqual(PeerDeviceRegistry.shared.knownDevices(of: peer).map(\.deviceId), ["d1"])
    }

    /// Cleared when the account changes under us: keeping the previous account's peers would
    /// attribute their devices to the new one.
    func testClearForgetsEverything() {
        PeerDeviceRegistry.shared.record(userId: peer, devices: [bundle("d1")])
        PeerDeviceRegistry.shared.clear()
        XCTAssertTrue(PeerDeviceRegistry.shared.knownDevices(of: peer).isEmpty)
    }
}
