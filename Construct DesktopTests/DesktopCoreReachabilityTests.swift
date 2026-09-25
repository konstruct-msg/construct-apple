//
//  DesktopCoreReachabilityTests.swift
//  Construct DesktopTests
//
//  Is the desktop's crypto the same crypto?
//
//  This target exists so the Mac can serve as a second real device in one account — multi-device
//  cannot be tested without one. A second device whose cryptography quietly differs from the first
//  does not merely fail to help; it produces divergences that read as multi-device defects and
//  cost the time of whoever chases them.
//
//  One such divergence shipped and lasted a month. `supports_pq_ratchet` was advertised to the
//  server under `#if os(iOS)`, correctly when written (2026-07-02, macOS reached the core through
//  `EngineAdapter`) and wrongly from 2026-07-28, when that indirection was retired and the guard
//  was not. Every macOS device told the server it could not do suite 3. It negotiated suite 3 as
//  initiator, because the capability is read from the *peer's* bundle, and was negotiated down as
//  responder. Nothing on either platform reported it.
//
//  (`supports_pq_ratchet` itself is gone since PQXDH v2: suite 3 is the only suite.)
//
//  So the guard's premise — "the core is not reachable here" — is what these tests deny, with the
//  core's own answers rather than with the fact that they compile. `CoreCapabilityPlatformParityTests`
//  in the iOS target asserts the other half: that no core call is left iOS-only.
//

import XCTest
import CryptoKit
@testable import Construct_Desktop

final class DesktopCoreReachabilityTests: XCTestCase {

    /// The Kyber prekeys a desktop publishes are ML-KEM-1024, and its core can open what is sealed
    /// to them. Since PQXDH v2 every session's first key depends on this, so a desktop core
    /// without it could not talk to anyone. (This test asserted `supportsPqRatchet()` before:
    /// suite 3 is no longer a capability to advertise but the only suite.)
    func testTheDesktopCoreHoldsAndOpensKyber1024Prekeys() throws {
        let keys = try createCryptoCore().exportPrivateKeys()
        let core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: "desktop-parity")
        _ = try core.ensureHybridSignatureKey()
        let spk = try core.beginKyberSpkRotation()
        XCTAssertEqual(spk.publicKey.count, 1568, "an ML-KEM-1024 encapsulation key")

        let sealed = try mlkem1024Encapsulate(publicKey: spk.publicKey)
        let opened = try core.kyberPrekeyDecapsulate(keyId: spk.keyId, ciphertext: sealed.ciphertext)
        XCTAssertEqual(opened, sealed.sharedSecret)
        XCTAssertEqual(sealed.ciphertext.count, 1568)
        XCTAssertFalse(sealed.sharedSecret.allSatisfy { $0 == 0 })
    }

    /// The identity-space rule, checked against its definition rather than against itself:
    /// a `CryptoDeviceId` is `SHA256(identity_public)[0..16]` in lowercase hex. If macOS derived
    /// device ids differently, every per-device address the desktop produced would be wrong and
    /// would look like a routing defect.
    func testDeviceIdDerivationMatchesItsDefinition() {
        let key = [UInt8](repeating: 0xA7, count: 32)
        let expected = SHA256.hash(data: Data(key)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(deriveDeviceId(identityPublicKey: key), expected)
        XCTAssertEqual(deriveDeviceId(identityPublicKey: key).count, 32)
    }

    /// Hybrid Ed25519 + ML-DSA-65 signing round-trips, and a tampered message fails. The desktop
    /// publishes a bundle signed this way; a platform where verification always said true would
    /// be a device that accepts anything.
    func testHybridSignatureRoundTripsAndRejectsTamperingOnMacOS() throws {
        let keys = try hybridSignatureKeygen()
        let message = [UInt8]("construct desktop parity".utf8)
        let signature = try hybridSign(privateKey: keys.privateKey, message: message)

        XCTAssertTrue(try hybridVerify(publicKey: keys.publicKey, message: message, signature: signature))

        var tampered = message
        tampered[0] ^= 0x01
        XCTAssertFalse(try hybridVerify(publicKey: keys.publicKey, message: tampered, signature: signature),
                       "a platform that verifies a tampered message accepts anything")
    }

    /// Tie-break decides which side is INITIATOR when both start at once, and it must give the
    /// same answer on both devices or they deadlock into mutual resets. Asserted as the property
    /// that matters — the two sides disagree about themselves and agree about the outcome.
    func testTieBreakIsSymmetricOnMacOS() {
        let a = "6f5e37ac1b2c3d4e5f60718293a4b5c6"
        let b = "0b4577bc9e8d7c6b5a4938271605f4e3"
        let roleOfA = tieBreakRole(myId: a, peerId: b)
        let roleOfB = tieBreakRole(myId: b, peerId: a)
        XCTAssertNotEqual(roleOfA, roleOfB, "both sides took the same role — that is a deadlock")
        XCTAssertEqual(Set([roleOfA, roleOfB]).count, 2)
    }
}
