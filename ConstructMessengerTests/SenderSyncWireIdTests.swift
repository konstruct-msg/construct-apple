//
//  SenderSyncWireIdTests.swift
//  ConstructMessengerTests
//
//  Delivery is not per device. `messaging-service/src/core.rs` fans a message out with
//  `fetch_recipient_device_ids`, writing the same envelope to every one of the recipient's
//  per-device streams, so an account with three devices receives on each of them the two copies
//  meant for the other two — and the sending device gets its own copy back. The `-ss-<tag>` suffix
//  the sender writes is what tells them apart.
//
//  Since 2026-08-17 the tag is a MAC under a secret only the two devices share, not the device id
//  in plain hex. These tests state both what it must do and what it must no longer say.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class SenderSyncWireIdTests: XCTestCase {

    private let base = "34f009c9-caa1-41a3-964e-40af9f3129a7"

    /// Two devices of one account: identity key pairs and ids, as the bundles would carry them.
    private struct Device {
        let id: String
        let priv: Data
        let pub: Data

        init(id: String) {
            let key = Curve25519.KeyAgreement.PrivateKey()
            self.id = id
            self.priv = key.rawRepresentation
            self.pub = key.publicKey.rawRepresentation
        }
    }

    private func secret(_ a: Device, _ b: Device) -> SymmetricKey {
        SenderSyncDeviceTag.pairSecret(ourIdentityPrivateKey: a.priv, peerIdentityPublicKey: b.pub)!
    }

    // MARK: - Reading the tag

    func testSingleChunkIdYieldsTheTargetTag() {
        XCTAssertEqual(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab"), "b3ed60ab")
        XCTAssertEqual(SenderSyncWireId.baseId(of: "\(base)-ss-b3ed60ab"), base)
    }

    /// A multi-chunk copy carries the chunk index after the tag. Cutting it is what keeps chunk 3
    /// of a copy from reading as a tag of its own.
    ///
    /// Mutation: drop the `-c` trim — the tag becomes "b3ed60ab-c3", matches nothing, and every
    /// chunk after the first is treated as foreign, so multi-chunk syncs never assemble.
    func testMultiChunkIdYieldsTheSameTagAndBase() {
        XCTAssertEqual(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab-c3"), "b3ed60ab")
        XCTAssertEqual(SenderSyncWireId.baseId(of: "\(base)-ss-b3ed60ab-c3"), base)
    }

    /// An ordinary message id is not a sender-sync id, and must not be read as one.
    func testOrdinaryMessageIdHasNoTag() {
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: base))
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: "\(base)-c2"))
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: ""))
        XCTAssertNil(SenderSyncWireId.baseId(of: base))
    }

    // MARK: - What the tag must not say

    /// The point of the change. The tag must not contain, or be derivable from, the device id —
    /// the relay routes every one of these copies and holds both devices' public keys.
    ///
    /// Mutation: return `targetDeviceId.prefix(8)` — this reddens, and it is exactly the form
    /// that shipped until 2026-08-17.
    func testTagRevealsNothingAboutTheDeviceId() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: secret(a, b))

        XCTAssertEqual(tag.count, SenderSyncDeviceTag.hexLength)
        XCTAssertFalse(b.id.hasPrefix(tag))
        XCTAssertFalse(tag.hasPrefix(String(b.id.prefix(8))))
        XCTAssertFalse(b.id.contains(tag))
    }

    /// A tag is per message, so two copies to the same device share nothing the relay could group by.
    ///
    /// Mutation: MAC the device id alone, dropping the message id — the tag becomes a stable
    /// per-device identifier again, just an opaque one.
    func testTagDiffersPerMessage() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let s = secret(a, b)
        let first = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: s)
        let second = SenderSyncDeviceTag.tag(
            baseMessageId: "7574fdec-ca31-44ac-9d43-0e6e870fe4d5", targetDeviceId: b.id, pairSecret: s
        )
        XCTAssertNotEqual(first, second)
    }

    /// Every chunk of one message carries the same tag — the MAC is over the base id, not the wire
    /// id. Otherwise chunk 2 would look like a copy for a different device.
    func testAllChunksOfOneMessageShareTheTag() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let s = secret(a, b)
        let tag = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: s)
        for chunk in 0..<4 {
            let wireId = chunk == 0 ? "\(base)-ss-\(tag)" : "\(base)-ss-\(tag)-c\(chunk)"
            XCTAssertEqual(SenderSyncWireId.targetDeviceTag(of: wireId), tag)
            XCTAssertEqual(SenderSyncWireId.baseId(of: wireId), base)
        }
    }

    // MARK: - Sorting copies on a two-device account

    /// The pair from the 2026-08-17 logs: annie's account had `bfbcef09…` and `b3ed60ab…`, each
    /// receiving the other's copies. A sends to B; the relay hands the copy to both.
    ///
    /// The sender's own echo is the case a symmetric tag would get wrong: A and B derive the same
    /// pair secret, so without the target device id in the MAC input A would read its own echo as
    /// addressed to itself and try to open a message it had just encrypted.
    ///
    /// Mutation: drop `targetDeviceId` from the MAC input — the echo assertion reddens.
    func testCopyForBIsForeignOnAAndOursOnB() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: secret(a, b))
        let wireId = "\(base)-ss-\(tag)"

        XCTAssertFalse(
            SenderSyncWireId.isForAnotherDevice(wireId: wireId, ourDeviceId: b.id, pairSecrets: [secret(b, a)]),
            "the addressed device must open it"
        )
        XCTAssertTrue(
            SenderSyncWireId.isForAnotherDevice(wireId: wireId, ourDeviceId: a.id, pairSecrets: [secret(a, b)]),
            "the sender's own echo must not be taken for a copy addressed to it"
        )
    }

    /// Three devices: C shares a secret with neither end of the A→B copy it receives.
    func testThirdDeviceSkipsACopyForSomeoneElse() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let c = Device(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        let tag = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: secret(a, b))

        XCTAssertTrue(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-\(tag)",
            ourDeviceId: c.id,
            pairSecrets: [secret(c, a), secret(c, b)]
        ))
    }

    // MARK: - Failing open

    /// Every case the receiver cannot decide must be treated as ours. Wrongly opening a copy costs
    /// failed decrypts; wrongly discarding one loses a message from the transcript, silently.
    ///
    /// Mutation: `return true` in any of these — copies stop arriving with nothing to show for it.
    func testUndecidableCasesAreTreatedAsOurs() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id, pairSecret: secret(a, b))

        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: base, ourDeviceId: b.id, pairSecrets: [secret(b, a)]), "not a sender-sync id")
        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-\(tag)", ourDeviceId: b.id, pairSecrets: []), "no secrets known yet")
        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-\(tag)", ourDeviceId: nil, pairSecrets: [secret(b, a)]), "no device id")
        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-zzz", ourDeviceId: b.id, pairSecrets: [secret(b, a)]), "unknown tag shape")
    }

    // MARK: - Senders at or below 0.18.0

    /// The legacy form is 8 hex characters of the device id, told apart from the new one by length
    /// alone. Prefix, not equality — comparing a full device id against a truncated tag never
    /// matches, and every copy including our own would be dropped as foreign.
    ///
    /// Removal condition is on the branch itself: no builds ≤ 0.18.0 left in the field.
    func testLegacyDeviceIdPrefixStillSorts() {
        let mine = "bfbcef09a4db589922c2cfd0cf34885a"
        let theirs = "b3ed60ab5d0ef2c01f292a40bcdc3465"

        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-bfbcef09", ourDeviceId: mine, pairSecrets: []))
        XCTAssertTrue(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-b3ed60ab", ourDeviceId: mine, pairSecrets: []))
        XCTAssertFalse(SenderSyncWireId.isForAnotherDevice(
            wireId: "\(base)-ss-b3ed60ab", ourDeviceId: theirs, pairSecrets: []))
    }

    // MARK: - The secret itself

    /// X25519 is symmetric in the pair: the sender derives against the target's bundle key, the
    /// receiver against each of its own devices' bundle keys, and they must agree — otherwise no
    /// tag ever matches and sender sync silently stops, exactly as it did before 0.18.0.
    func testPairSecretIsSymmetric() {
        let a = Device(id: "a")
        let b = Device(id: "b")
        XCTAssertEqual(secret(a, b), secret(b, a))
    }

    func testPairSecretRejectsMalformedKeyMaterial() {
        let a = Device(id: "a")
        XCTAssertNil(SenderSyncDeviceTag.pairSecret(ourIdentityPrivateKey: Data([0x01]), peerIdentityPublicKey: a.pub))
        XCTAssertNil(SenderSyncDeviceTag.pairSecret(ourIdentityPrivateKey: a.priv, peerIdentityPublicKey: Data()))
    }
}
