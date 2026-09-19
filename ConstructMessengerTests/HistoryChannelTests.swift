//
//  HistoryChannelTests.swift
//  ConstructMessengerTests
//
//  The refusal rules between the directory's answer and a history transfer, and what the
//  link QR leaves behind for the verifier. No server, no core session.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class HistoryChannelTests: XCTestCase {

    // MARK: - Bundle → peer keys

    private func entry(
        identity: Curve25519.KeyAgreement.PrivateKey = .init(),
        hybrid: Data = Data(repeating: 0x42, count: CTT1V2Layout.hybridPubCount),
        kyber: Data? = Data(repeating: 0x07, count: 1184),
        kyberId: UInt32? = 9,
        deviceIdOverride: String? = nil
    ) -> DeviceBundleData {
        let identityPublic = identity.publicKey.rawRepresentation
        var bundle = PublicKeyBundleData(
            userId: "e7a4e3d2-0000-4000-8000-000000000001",
            username: "",
            identityPublic: identityPublic,
            signedPrekeyPublic: Data(repeating: 0, count: 32),
            signature: Data(repeating: 0, count: 64),
            verifyingKey: Data(repeating: 0, count: 32),
            suiteId: 1,
            spkUploadedAt: 0,
            spkRotationEpoch: 0,
            kyberSpkUploadedAt: 0,
            kyberSpkRotationEpoch: 0
        )
        bundle.kyberPreKeyPublic = kyber
        bundle.kyberPreKeyId = kyberId
        return DeviceBundleData(
            deviceId: deviceIdOverride ?? deriveDeviceId(identityPublicKey: [UInt8](identityPublic)),
            bundle: bundle,
            platform: .ios,
            hybridIdentityKey: hybrid
        )
    }

    func testCompleteBundleReduces() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let e = entry(identity: key)
        let peer = try HistoryChannel.peerKeys(from: e, pinnedIdentity: nil)
        XCTAssertEqual(peer.deviceIdHex, e.deviceId)
        XCTAssertEqual(peer.deviceIdRaw, HistoryChannel.rawDeviceId(e.deviceId))
        XCTAssertEqual(peer.identityPublic, key.publicKey.rawRepresentation)
        XCTAssertEqual(peer.kyberSPKId, 9)
    }

    func testMissingHybridKeyRefuses() {
        XCTAssertThrowsError(try HistoryChannel.peerKeys(from: entry(hybrid: Data()), pinnedIdentity: nil)) {
            XCTAssertEqual($0 as? CTT1V2Error, .noHybridKey)
        }
    }

    func testMissingKyberSPKRefusesAsNoHybridKey() {
        XCTAssertThrowsError(try HistoryChannel.peerKeys(from: entry(kyber: nil, kyberId: nil), pinnedIdentity: nil)) {
            XCTAssertEqual($0 as? CTT1V2Error, .noHybridKey)
        }
    }

    /// The directory labelled a bundle with a device id its identity key does not derive to.
    func testDeviceIdNotDerivedFromIdentityIsMismatch() {
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let e = entry(deviceIdOverride: deriveDeviceId(identityPublicKey: [UInt8](other)))
        XCTAssertThrowsError(try HistoryChannel.peerKeys(from: e, pinnedIdentity: nil)) {
            XCTAssertEqual($0 as? CTT1V2Error, .identityMismatch)
        }
    }

    func testFlowBPinMatchesAndMismatches() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let e = entry(identity: key)
        XCTAssertNoThrow(try HistoryChannel.peerKeys(from: e, pinnedIdentity: key.publicKey.rawRepresentation))
        let wrong = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try HistoryChannel.peerKeys(from: e, pinnedIdentity: wrong)) {
            XCTAssertEqual($0 as? CTT1V2Error, .qrPinMismatch)
        }
    }

    // MARK: - What the QR left behind

    func testTrustReflectsWhichFlowLinked() {
        let user = "trust-test-" + UUID().uuidString
        defer { DeviceLinkPendingPin.clear(forUserId: user) }
        XCTAssertEqual(DeviceLinkPendingPin.trust(forUserId: user), .absent)

        DeviceLinkPendingPin.markBundleOnly(userId: user)
        XCTAssertEqual(DeviceLinkPendingPin.trust(forUserId: user), .bundleOnly)

        let fp = Data(repeating: 0xAB, count: 32)
        let token = "tok-" + UUID().uuidString
        DeviceLinkPendingPin.store(fp, forToken: token)
        DeviceLinkPendingPin.bindToAccount(userId: user, fromToken: token)
        XCTAssertEqual(DeviceLinkPendingPin.trust(forUserId: user), .pinned(fp), "a real pin outranks bundle_only")
        XCTAssertNil(DeviceLinkPendingPin.load(forToken: token), "token slot is consumed by binding")

        DeviceLinkPendingPin.clear(forUserId: user)
        XCTAssertEqual(DeviceLinkPendingPin.trust(forUserId: user), .absent, "clear drops both markers")
    }

    func testFlowBPeerIdentityIsHeldPerDevice() {
        let device = "dev-" + UUID().uuidString
        defer { DeviceLinkPendingPin.clearPeerIdentity(forDeviceId: device) }
        XCTAssertNil(DeviceLinkPendingPin.peerIdentity(forDeviceId: device))
        DeviceLinkPendingPin.storePeerIdentity(Data(repeating: 1, count: 31), forDeviceId: device)
        XCTAssertNil(DeviceLinkPendingPin.peerIdentity(forDeviceId: device), "a 31-byte key is not an X25519 key")
        let key = Data(repeating: 1, count: 32)
        DeviceLinkPendingPin.storePeerIdentity(key, forDeviceId: device)
        XCTAssertEqual(DeviceLinkPendingPin.peerIdentity(forDeviceId: device), key)
    }

    // MARK: - Ids

    func testRawDeviceIdRoundTrip() {
        let hex = "00ff10a5b6c7d8e9f0112233445566778899aabbccddeeff".prefix(32)
        let raw = HistoryChannel.rawDeviceId(String(hex))
        XCTAssertEqual(raw?.count, 16)
        XCTAssertEqual(raw?.map { String(format: "%02x", $0) }.joined(), String(hex))
        XCTAssertNil(HistoryChannel.rawDeviceId("abc"))
        XCTAssertNil(HistoryChannel.rawDeviceId(String(repeating: "zz", count: 16)))
    }

    // MARK: - Every named reason has its own sentence

    func testNamedReasonsDoNotCollapseIntoCorrupt() {
        let corrupt = NSLocalizedString("transfer_error_corrupt", comment: "")
        for reason: CTT1V2Error in [.qrPinMismatch, .qrPinAbsent, .kemKeyIdMismatch, .noHybridKey] {
            XCTAssertNotEqual(HistoryTransferUserMessage.text(for: reason), corrupt, "\(reason)")
        }
        XCTAssertNotEqual(HistoryTransferUserMessage.text(for: HistoryChannelError.peerNotInDirectory), corrupt)
        XCTAssertEqual(HistoryTransferUserMessage.text(for: CTT1V2Error.signatureInvalid), corrupt)
    }
}
