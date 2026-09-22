//
//  AccountSendTagTests.swift
//  ConstructMessengerTests
//
//  The ordinary send names its device too, or names nothing — never the wrong one.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class AccountSendTagTests: XCTestCase {

    private let uuid = "34f009c9-caa1-41a3-964e-40af9f3129a7"

    // MARK: - Chunk suffix

    /// All chunks of one message must share a tag, so the tag is computed over the logical id and
    /// the `-c<n>` suffix is reattached after. Tagging `<uuid>-c1` whole would verify correctly and
    /// still break that invariant, which is why this is split out and tested directly.
    func testChunkSuffixIsSplitOffAndTheIndexKept() {
        let (id0, i0) = AccountSendTag.splitChunkSuffix(uuid)
        XCTAssertEqual(id0, uuid)
        XCTAssertNil(i0, "chunk 0 is the bare id — there is no suffix to split")

        let (id3, i3) = AccountSendTag.splitChunkSuffix("\(uuid)-c3")
        XCTAssertEqual(id3, uuid)
        XCTAssertEqual(i3, 3)
    }

    /// A UUID contains no `-c<digits>` group, but the split must not be fooled by one that is not a
    /// chunk suffix either — `-c` followed by anything unparseable stays part of the id.
    func testNonNumericSuffixIsNotAChunk() {
        let (id, index) = AccountSendTag.splitChunkSuffix("\(uuid)-cabc")
        XCTAssertEqual(id, "\(uuid)-cabc")
        XCTAssertNil(index)
    }

    // MARK: - Failing open

    /// Every case that cannot attribute the copy returns the id unchanged. The receiver then walks
    /// its sessions exactly as it did before §D — degraded, never wrong.
    func testUnattributableSendsAreLeftUntagged() {
        XCTAssertEqual(
            AccountSendTag.wireId(baseMessageId: uuid, recipientId: ""),
            uuid, "no recipient"
        )
        XCTAssertEqual(
            AccountSendTag.wireId(baseMessageId: "", recipientId: "14f28d31-2dab-44aa-a123-456789abcdef"),
            "", "no message id"
        )
    }

    /// A fan-out copy arrives here fully formed. Tagging it again would put a second marker in the
    /// id, and `DeviceCopyWireId` reads the **last** one — so the receiver would verify a tag over
    /// the wrong base and discard its own message as foreign.
    func testAnAlreadyTaggedCopyIsReturnedUntouched() {
        let already = "\(uuid)-fd-0123456789abcdef"
        XCTAssertEqual(
            AccountSendTag.wireId(baseMessageId: already, recipientId: "14f28d31-2dab-44aa-a123-456789abcdef"),
            already
        )
        let ownReplica = "\(uuid)-ss-0123456789abcdef"
        XCTAssertEqual(
            AccountSendTag.wireId(baseMessageId: ownReplica, recipientId: "14f28d31-2dab-44aa-a123-456789abcdef"),
            ownReplica
        )
    }

    // MARK: - The round trip

    /// The point: what the ordinary send writes, the recipient can attribute back to the sending
    /// device — the same reading the fan-out copies already got.
    ///
    /// Goes through `AccountSendTag.wireId` rather than building the id by hand. The first version
    /// of this test did build it by hand, and the mutation `return baseMessageId` from `wireId`
    /// survived: it asserted that the tag format round-trips, which was never in doubt, and not
    /// that the ordinary send produces one.
    ///
    /// Mutation: `return baseMessageId` at the top of `wireId` — `senderDevice` goes nil and this
    /// reddens, which is the state every ordinary send was in before §D.
    func testTaggedPrimarySendNamesTheSenderToTheRecipient() {
        let senderKey = Curve25519.KeyAgreement.PrivateKey()
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerAccount = "14f28d31-2dab-44aa-a123-456789abcdef"
        let peerDevice = deriveDeviceId(identityPublicKey: [UInt8](peerKey.publicKey.rawRepresentation))

        AccountSendTag.keys = AccountSendTag.Keys(
            ourIdentityPrivate: { senderKey.rawRepresentation },
            pinnedIdentityPublic: { $0 == peerAccount ? peerKey.publicKey.rawRepresentation : nil },
            pinnedDevice: { $0 == peerAccount ? peerDevice : nil },
            deviceIdentityPublic: { _ in nil }
        )
        defer { AccountSendTag.keys = .production }

        // What the send path would put on the envelope.
        let wireId = AccountSendTag.wireId(baseMessageId: uuid, recipientId: peerAccount)
        XCTAssertNotEqual(wireId, uuid, "an ordinary send to a pinned device must carry a tag")
        XCTAssertEqual(DeviceCopyWireId.baseId(of: wireId), uuid)

        // The recipient reads it back and names the writer.
        let reading = DeviceCopyWireId.read(
            wireId: wireId,
            ourDeviceId: peerDevice,
            ourIdentityPrivateKey: peerKey.rawRepresentation,
            peerIdentityKeys: [senderKey.publicKey.rawRepresentation],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .ours)
        XCTAssertEqual(
            reading.senderDevice,
            deriveDeviceId(identityPublicKey: [UInt8](senderKey.publicKey.rawRepresentation)),
            "an ordinary send must be as attributable as a fan-out copy"
        )
    }

    /// All chunks of one message carry the same tag, so a receiver can recompute it from whichever
    /// chunk arrives first — and the shape matches the fan-out's, `<uuid>-fd-<tag>-c<n>`.
    func testEveryChunkOfOneMessageCarriesTheSameTag() {
        let senderKey = Curve25519.KeyAgreement.PrivateKey()
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerAccount = "14f28d31-2dab-44aa-a123-456789abcdef"
        let peerDevice = deriveDeviceId(identityPublicKey: [UInt8](peerKey.publicKey.rawRepresentation))

        AccountSendTag.keys = AccountSendTag.Keys(
            ourIdentityPrivate: { senderKey.rawRepresentation },
            pinnedIdentityPublic: { _ in peerKey.publicKey.rawRepresentation },
            pinnedDevice: { _ in peerDevice },
            deviceIdentityPublic: { _ in nil }
        )
        defer { AccountSendTag.keys = .production }

        let first = AccountSendTag.wireId(baseMessageId: uuid, recipientId: peerAccount)
        let third = AccountSendTag.wireId(baseMessageId: "\(uuid)-c3", recipientId: peerAccount)

        XCTAssertEqual(
            DeviceCopyWireId.targetDeviceTag(of: first),
            DeviceCopyWireId.targetDeviceTag(of: third),
            "a per-chunk tag would break recomputation from whichever chunk arrives first"
        )
        XCTAssertTrue(third.hasSuffix("-c3"), "the chunk suffix stays last: \(third)")
        XCTAssertEqual(DeviceCopyWireId.baseId(of: third), uuid)
    }

    /// A send that names a device other than the pinned one is tagged under **that** device's
    /// key. Until 2026-09-22 it was tagged under the pinned key with the named device's id — a
    /// MAC the named device could never reproduce, so its own control read as "for a sibling".
    ///
    /// Mutation: take `pinnedIdentityPublic` for a named device — the second device's reading
    /// stops being `.ours` and this reddens.
    func testANamedDeviceIsTaggedUnderItsOwnKey() {
        let senderKey = Curve25519.KeyAgreement.PrivateKey()
        let pinnedKey = Curve25519.KeyAgreement.PrivateKey()
        let secondKey = Curve25519.KeyAgreement.PrivateKey()
        let peerAccount = "14f28d31-2dab-44aa-a123-456789abcdef"
        let pinnedDevice = deriveDeviceId(identityPublicKey: [UInt8](pinnedKey.publicKey.rawRepresentation))
        let secondDevice = deriveDeviceId(identityPublicKey: [UInt8](secondKey.publicKey.rawRepresentation))

        AccountSendTag.keys = AccountSendTag.Keys(
            ourIdentityPrivate: { senderKey.rawRepresentation },
            pinnedIdentityPublic: { _ in pinnedKey.publicKey.rawRepresentation },
            pinnedDevice: { _ in pinnedDevice },
            deviceIdentityPublic: { $0 == secondDevice ? secondKey.publicKey.rawRepresentation : nil }
        )
        defer { AccountSendTag.keys = .production }

        let wireId = AccountSendTag.wireId(
            baseMessageId: uuid, recipientId: peerAccount, recipientDeviceId: secondDevice
        )
        XCTAssertNotEqual(wireId, uuid, "a named device with a known key must be tagged")

        let reading = DeviceCopyWireId.read(
            wireId: wireId,
            ourDeviceId: secondDevice,
            ourIdentityPrivateKey: secondKey.rawRepresentation,
            peerIdentityKeys: [senderKey.publicKey.rawRepresentation],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .ours, "the named device must read its own control as its own")
    }
}
