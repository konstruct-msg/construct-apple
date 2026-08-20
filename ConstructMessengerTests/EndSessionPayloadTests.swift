//
//  EndSessionPayloadTests.swift
//  ConstructMessengerTests
//
//  END_SESSION is the one carrier that cannot be encrypted with the ratchet. Until 2026-08-17 that
//  was taken to mean it could not be protected at all: the reset reason went out as a plaintext
//  proto, on a payload of 4 or 16 bytes, while SealedInner hid the content type. These tests state
//  what the wire must look like now, in bytes rather than in intent.
//

import XCTest
import CryptoKit
import SwiftProtobuf
@testable import Construct_Messenger

final class EndSessionPayloadTests: XCTestCase {

    private func identityKeyPair() -> (priv: Data, pub: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    // MARK: - Size

    /// Every END_SESSION is the same length, and that length is a body bucket. Otherwise the relay
    /// identifies the message by size no matter what the content type says.
    func testPayload_IsAlwaysOneBucketLong_WhateverItCarries() {
        let (_, pub) = identityKeyPair()
        let cases: [(String, Data)] = [
            ("with a reason",    EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)),
            ("without a reason", EndSessionPayload.build(reason: .unspecified, recipientIdentityKey: pub)),
            ("unsealable",       EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: nil)),
        ]
        for (label, payload) in cases {
            XCTAssertEqual(payload.count, EndSessionPayload.paddedSize,
                           "\(label): END_SESSION must not be identifiable by length")
        }
        XCTAssertEqual(EndSessionPayload.paddedSize, 1024, "must match the smallest body bucket")
    }

    /// The reason must not be readable from the payload by anyone holding it — which includes the
    /// relay, since `encrypted_payload` is not encrypted on this carrier.
    func testPayload_DoesNotContainThePlaintextReason() throws {
        let (_, pub) = identityKeyPair()
        var control = Shared_Proto_Messaging_V1_SessionControl()
        control.op = .end
        control.reason = .otpkUnreproducible
        let plaintext = try control.serializedData()

        let payload = EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)
        XCTAssertFalse(payload.range(of: plaintext) != nil,
                       "the serialised SessionControl must not appear anywhere in the payload")
    }

    /// Two teardowns to the same peer must share no bytes — a fresh ephemeral per call. A fixed
    /// box would let the relay group END_SESSIONs by recipient without reading them.
    func testPayload_TwoSendsShareNoPrefix() {
        let (_, pub) = identityKeyPair()
        let a = EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)
        let b = EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.prefix(EndSessionPayload.boxSize), b.prefix(EndSessionPayload.boxSize))
    }

    // MARK: - Round trip

    func testReason_RoundTripsToTheIntendedRecipient() {
        let (priv, pub) = identityKeyPair()
        let payload = EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)
        XCTAssertEqual(EndSessionPayload.reason(from: payload, ourIdentityPrivateKey: priv),
                       .otpkUnreproducible)
    }

    func testReason_UnspecifiedRoundTrips() {
        let (priv, pub) = identityKeyPair()
        let payload = EndSessionPayload.build(reason: .unspecified, recipientIdentityKey: pub)
        XCTAssertEqual(EndSessionPayload.reason(from: payload, ourIdentityPrivateKey: priv), .unspecified)
    }

    /// A hint is not an authorisation: every way of failing to read one yields `.unspecified`, and
    /// END_SESSION is still acted on. None of these may throw or crash.
    func testReason_EveryFailureYieldsUnspecified() {
        let (priv, pub) = identityKeyPair()
        let (otherPriv, _) = identityKeyPair()
        let sealed = EndSessionPayload.build(reason: .otpkUnreproducible, recipientIdentityKey: pub)

        XCTAssertEqual(EndSessionPayload.reason(from: sealed, ourIdentityPrivateKey: otherPriv), .unspecified,
                       "sealed to another identity")
        XCTAssertEqual(EndSessionPayload.reason(from: sealed, ourIdentityPrivateKey: nil), .unspecified,
                       "no identity key in the keychain")
        XCTAssertEqual(EndSessionPayload.reason(from: Data(), ourIdentityPrivateKey: priv), .unspecified,
                       "empty payload")
        XCTAssertEqual(EndSessionPayload.reason(from: Data(count: 16), ourIdentityPrivateKey: priv), .unspecified,
                       "the legacy 16-byte sentinel")
        XCTAssertEqual(EndSessionPayload.reason(from: Data(repeating: 0xAB, count: 1024),
                                                ourIdentityPrivateKey: priv), .unspecified,
                       "1024 bytes that are not a box")
        XCTAssertEqual(EndSessionPayload.reason(from: sealed, ourIdentityPrivateKey: Data([0x01])), .unspecified,
                       "malformed identity key")
    }

    /// Compatibility with senders at or below 0.18.0, which put a bare SessionControl on the wire.
    /// Removal condition is recorded on the fallback itself.
    func testReason_ReadsTheLegacyPlaintextForm() throws {
        var control = Shared_Proto_Messaging_V1_SessionControl()
        control.op = .end
        control.reason = .otpkUnreproducible
        let legacy = try control.serializedData()

        let (priv, _) = identityKeyPair()
        XCTAssertEqual(EndSessionPayload.reason(from: legacy, ourIdentityPrivateKey: priv), .otpkUnreproducible)
    }

    // MARK: - Domain separation

    /// A box sealed as a sender certificate must not open as an END_SESSION reason. The two share
    /// one construction (`sealToIdentity`) and are told apart only by their domain string.
    func testIdentityBox_DoesNotOpenUnderAnotherDomain() throws {
        let (priv, pub) = identityKeyPair()
        let box = try StealthSenderService.sealToIdentity(Data("payload".utf8),
                                                          recipientIdentityKey: pub,
                                                          domain: "ConstructSEALED-v1")
        XCTAssertThrowsError(
            try StealthSenderService.openFromIdentity(box, ourIdentityPrivKeyBytes: priv,
                                                      domain: "ConstructENDSESSION-v1")
        )
        XCTAssertEqual(
            try StealthSenderService.openFromIdentity(box, ourIdentityPrivKeyBytes: priv,
                                                      domain: "ConstructSEALED-v1"),
            Data("payload".utf8)
        )
    }
}
