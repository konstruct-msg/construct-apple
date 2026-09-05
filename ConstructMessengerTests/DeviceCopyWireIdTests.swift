//
//  DeviceCopyWireIdTests.swift
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

final class DeviceCopyWireIdTests: XCTestCase {

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

    /// The tag `from` writes for a copy addressed to `to`.
    ///
    /// The pair secret is no longer a value this test can hold: it is derived inside the core from
    /// the two identity keys (2026-08-25, `crypto::device_copy_tag`). Force-unwrapped because a
    /// `nil` here means the fixture keys are malformed, not that the code under test decided
    /// anything — and a test that silently skipped on bad fixtures would pass forever.
    private func tag(from: Device, to: Device, messageId: String? = nil) -> String {
        SenderSyncDeviceTag.tag(
            baseMessageId: messageId ?? base,
            targetDeviceId: to.id,
            ourIdentityPrivateKey: from.priv,
            peerIdentityPublicKey: to.pub
        )!
    }

    /// The id the app would actually hold for a device, derived from its identity key exactly as
    /// `SessionAddressing.cryptoIdentity` and the core's `derive_device_id` do. The fixture's
    /// `Device.id` is an arbitrary literal; §D returns the derived one, because the key that
    /// reproduced the MAC is the only evidence there is.
    private func derivedId(_ d: Device) -> String {
        deriveDeviceId(identityPublicKey: [UInt8](d.pub))
    }

    // MARK: - §D: the tag names the device that wrote the copy

    /// The point of §D. Verifying the tag already had to try each candidate key; the one that
    /// reproduces the MAC is the sender, and it used to be discarded.
    ///
    /// Mutation: return `senderDevice: nil` on the `.ours` branch — this reddens, and the receive
    /// path silently goes back to guessing by walking every session.
    func testTheMatchingKeyNamesTheSender() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let reading = DeviceCopyWireId.read(
            wireId: "\(base)-fd-\(tag(from: a, to: b))",
            ourDeviceId: b.id,
            ourIdentityPrivateKey: b.priv,
            peerIdentityKeys: [a.pub],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .ours)
        XCTAssertEqual(reading.senderDevice, derivedId(a), "the key that reproduced the MAC is the writer")
    }

    /// The sender is picked out of a set, not confirmed against a guess — which is the whole
    /// difference from the pinned-device assumption that archived a healthy neighbour session.
    func testSenderIsIdentifiedAmongSeveralCandidateDevices() {
        let phone   = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let desktop = Device(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        let us      = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")

        // Their Desktop writes to us, with their phone listed first among the candidates.
        let reading = DeviceCopyWireId.read(
            wireId: "\(base)-fd-\(tag(from: desktop, to: us))",
            ourDeviceId: us.id,
            ourIdentityPrivateKey: us.priv,
            peerIdentityKeys: [phone.pub, desktop.pub],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .ours)
        XCTAssertEqual(reading.senderDevice, derivedId(desktop),
                       "naming the first candidate instead of the matching one is the 20/20 misattribution")
        XCTAssertNotEqual(reading.senderDevice, derivedId(phone))
    }

    /// A copy for a sibling names no sender: its tag was written for a device id we did not bind,
    /// so nothing here attributes a writer. `nil` must mean "unknown", never "the pinned one".
    func testForeignCopyNamesNoSender() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let reading = DeviceCopyWireId.read(
            wireId: "\(base)-ss-\(tag(from: a, to: b))",
            ourDeviceId: a.id,                    // a receives its own echo
            ourIdentityPrivateKey: a.priv,
            peerIdentityKeys: [b.pub],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .foreign)
        XCTAssertNil(reading.senderDevice)
    }

    /// The legacy 8-hex form encodes the **target** device and involves no pair secret, so it can
    /// place a copy but can never attribute one.
    func testLegacyTagPlacesTheCopyButNamesNoSender() {
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let reading = DeviceCopyWireId.read(
            wireId: "\(base)-ss-b3ed60ab",
            ourDeviceId: b.id,
            ourIdentityPrivateKey: b.priv,
            peerIdentityKeys: [],
            peerDeviceSetIsComplete: true
        )
        XCTAssertEqual(reading.verdict, .ours)
        XCTAssertNil(reading.senderDevice, "a truncated device id is not evidence of who wrote it")
    }

    /// An untagged id — every ordinary send today — names nobody. This is the measured gap: the
    /// primary send carries a bare UUID, so §D covers fan-out copies only until it goes.
    func testUntaggedIdNamesNoSender() {
        XCTAssertNil(DeviceCopyWireId.read(
            wireId: base, ourDeviceId: "b3ed60ab5d0ef2c01f292a40bcdc3465",
            ourIdentityPrivateKey: Device(id: "x").priv, peerIdentityKeys: [Device(id: "y").pub],
            peerDeviceSetIsComplete: true
        ).senderDevice)
    }

    // MARK: - Reading the tag

    func testSingleChunkIdYieldsTheTargetTag() {
        XCTAssertEqual(DeviceCopyWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab"), "b3ed60ab")
        XCTAssertEqual(DeviceCopyWireId.baseId(of: "\(base)-ss-b3ed60ab"), base)
    }

    /// A multi-chunk copy carries the chunk index after the tag. Cutting it is what keeps chunk 3
    /// of a copy from reading as a tag of its own.
    ///
    /// Mutation: drop the `-c` trim — the tag becomes "b3ed60ab-c3", matches nothing, and every
    /// chunk after the first is treated as foreign, so multi-chunk syncs never assemble.
    func testMultiChunkIdYieldsTheSameTagAndBase() {
        XCTAssertEqual(DeviceCopyWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab-c3"), "b3ed60ab")
        XCTAssertEqual(DeviceCopyWireId.baseId(of: "\(base)-ss-b3ed60ab-c3"), base)
    }

    /// An ordinary message id is not a sender-sync id, and must not be read as one.
    func testOrdinaryMessageIdHasNoTag() {
        XCTAssertNil(DeviceCopyWireId.targetDeviceTag(of: base))
        XCTAssertNil(DeviceCopyWireId.targetDeviceTag(of: "\(base)-c2"))
        XCTAssertNil(DeviceCopyWireId.targetDeviceTag(of: ""))
        XCTAssertNil(DeviceCopyWireId.baseId(of: base))
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
        let tag = tag(from: a, to: b)

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
        let first = tag(from: a, to: b)
        let second = tag(from: a, to: b, messageId: "7574fdec-ca31-44ac-9d43-0e6e870fe4d5")
        XCTAssertNotEqual(first, second)
    }

    /// Every chunk of one message carries the same tag — the MAC is over the base id, not the wire
    /// id. Otherwise chunk 2 would look like a copy for a different device.
    func testAllChunksOfOneMessageShareTheTag() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = tag(from: a, to: b)
        for chunk in 0..<4 {
            let wireId = chunk == 0 ? "\(base)-ss-\(tag)" : "\(base)-ss-\(tag)-c\(chunk)"
            XCTAssertEqual(DeviceCopyWireId.targetDeviceTag(of: wireId), tag)
            XCTAssertEqual(DeviceCopyWireId.baseId(of: wireId), base)
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
        let tag = tag(from: a, to: b)
        let wireId = "\(base)-ss-\(tag)"

        XCTAssertEqual(
            DeviceCopyWireId.read(wireId: wireId, ourDeviceId: b.id,
                                     ourIdentityPrivateKey: b.priv, peerIdentityKeys: [a.pub], peerDeviceSetIsComplete: true).verdict,
            .ours,
            "the addressed device must open it"
        )
        XCTAssertEqual(
            DeviceCopyWireId.read(wireId: wireId, ourDeviceId: a.id,
                                     ourIdentityPrivateKey: a.priv, peerIdentityKeys: [b.pub], peerDeviceSetIsComplete: true).verdict,
            .foreign,
            "the sender's own echo must not be taken for a copy addressed to it"
        )
    }

    /// Three devices: C shares a secret with neither end of the A→B copy it receives.
    func testThirdDeviceSkipsACopyForSomeoneElse() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let c = Device(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        let tag = tag(from: a, to: b)

        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-\(tag)",
            ourDeviceId: c.id,
            ourIdentityPrivateKey: c.priv,
            peerIdentityKeys: [a.pub, b.pub], peerDeviceSetIsComplete: true
        ).verdict, .foreign)
    }

    // MARK: - Failing open

    /// Every case the receiver cannot decide must be treated as ours. Wrongly opening a copy costs
    /// failed decrypts; wrongly discarding one loses a message from the transcript, silently.
    ///
    /// Mutation: `return true` in any of these — copies stop arriving with nothing to show for it.
    func testUndecidableCasesAreTreatedAsOurs() {
        let a = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let b = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = tag(from: a, to: b)

        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: base, ourDeviceId: b.id, ourIdentityPrivateKey: b.priv, peerIdentityKeys: [a.pub], peerDeviceSetIsComplete: true).verdict, .undecidable, "not a sender-sync id")
        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-\(tag)", ourDeviceId: b.id, ourIdentityPrivateKey: b.priv, peerIdentityKeys: [], peerDeviceSetIsComplete: true).verdict, .undecidable, "no secrets known yet")
        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-\(tag)", ourDeviceId: nil, ourIdentityPrivateKey: b.priv, peerIdentityKeys: [a.pub], peerDeviceSetIsComplete: true).verdict, .undecidable, "no device id")
        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-zzz", ourDeviceId: b.id, ourIdentityPrivateKey: b.priv, peerIdentityKeys: [a.pub], peerDeviceSetIsComplete: true).verdict, .undecidable, "unknown tag shape")
    }

    // MARK: - A copy from a peer, where we know less

    /// The asymmetry that keeps a message from being lost.
    ///
    /// For a copy from one of our own devices we hold every sibling's public key, so a tag that
    /// reproduces for none of them is definitively for a sibling. For a copy from a **peer** we
    /// hold at most one of their identity keys — pinned at invite — and no list of their devices
    /// exists locally, so a non-match means either "for another of my devices" or "sent from a
    /// device of theirs I never pinned".
    ///
    /// Mutation: return `.foreign` for a non-matching recipient copy — this reddens, and in the
    /// field it discards our own message every time a multi-device peer writes from an unpinned
    /// device, silently.
    func testANonMatchingPeerCopyIsUndecidableNotForeign() {
        let me = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let peerKnown = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let peerUnpinned = Device(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9")

        // The peer wrote from a device we have never pinned, addressing us.
        let tag = tag(from: peerUnpinned, to: me)

        XCTAssertEqual(
            DeviceCopyWireId.read(
                wireId: "\(base)\(DeviceDeliveryPlan.Marker.recipient)\(tag)",
                ourDeviceId: me.id,
                ourIdentityPrivateKey: me.priv,
                peerIdentityKeys: [peerKnown.pub],
                peerDeviceSetIsComplete: false
            ).verdict,
            .undecidable,
            "a copy we cannot place must be attempted, never discarded"
        )
    }

    /// Once the peer's device set is known, the same copy IS decidable — which is the whole point
    /// of `PeerDeviceRegistry`. Before it existed this path could only ever say "attempt it", so
    /// the tag bought nothing on copies from a peer: no skipped candidate walk, no avoided bundle
    /// fetch on a `messageNumber == 0` copy.
    ///
    /// Mutation: ignore `peerDeviceSetIsComplete` and always return `.undecidable` for peer
    /// copies — this reddens while the loss-of-message test above stays green, which is why both
    /// exist.
    func testAKnownPeerDeviceSetMakesTheSameCopyDecidable() {
        let me = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let peer = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let mySibling = Device(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9")

        // The peer addressed our sibling, not us.
        let tag = tag(from: peer, to: mySibling)

        XCTAssertEqual(
            DeviceCopyWireId.read(
                wireId: "\(base)\(DeviceDeliveryPlan.Marker.recipient)\(tag)",
                ourDeviceId: me.id,
                ourIdentityPrivateKey: me.priv,
                peerIdentityKeys: [peer.pub],
                peerDeviceSetIsComplete: true
            ).verdict,
            .foreign
        )
    }

    /// The same shape from our own account IS decidable, because we hold every sibling's key.
    func testANonMatchingOwnReplicaCopyIsForeign() {
        let me = Device(id: "bfbcef09a4db589922c2cfd0cf34885a")
        let sibling = Device(id: "b3ed60ab5d0ef2c01f292a40bcdc3465")
        let tag = tag(from: me, to: sibling)

        XCTAssertEqual(
            DeviceCopyWireId.read(
                wireId: "\(base)\(DeviceDeliveryPlan.Marker.ownReplica)\(tag)",
                ourDeviceId: me.id,
                ourIdentityPrivateKey: me.priv,
                peerIdentityKeys: [sibling.pub], peerDeviceSetIsComplete: true
            ).verdict,
            .foreign
        )
    }

    /// Both markers are read. `-fd-` had no reader at all until 2026-08-25, which is why the leak
    /// it carried went unnoticed: nothing consumed the field, so nothing objected to its contents.
    func testBothMarkersAreRecognised() {
        let tagValue = "13819e444aa59d15"
        for marker in [DeviceDeliveryPlan.Marker.ownReplica, DeviceDeliveryPlan.Marker.recipient] {
            let id = "\(base)\(marker)\(tagValue)"
            XCTAssertEqual(DeviceCopyWireId.targetDeviceTag(of: id), tagValue, marker)
            XCTAssertEqual(DeviceCopyWireId.baseId(of: id), base, marker)
        }
        XCTAssertEqual(DeviceCopyWireId.audience(of: "\(base)-ss-\(tagValue)"), .ownReplica)
        XCTAssertEqual(DeviceCopyWireId.audience(of: "\(base)-fd-\(tagValue)"), .recipient)
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

        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-bfbcef09", ourDeviceId: mine,
            ourIdentityPrivateKey: nil, peerIdentityKeys: [], peerDeviceSetIsComplete: true).verdict, .ours)
        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-b3ed60ab", ourDeviceId: mine,
            ourIdentityPrivateKey: nil, peerIdentityKeys: [], peerDeviceSetIsComplete: true).verdict, .foreign)
        XCTAssertEqual(DeviceCopyWireId.read(
            wireId: "\(base)-ss-b3ed60ab", ourDeviceId: theirs,
            ourIdentityPrivateKey: nil, peerIdentityKeys: [], peerDeviceSetIsComplete: true).verdict, .ours)
    }

    // MARK: - The secret itself

    /// X25519 is symmetric in the pair: the sender derives against the target's bundle key, the
    /// receiver against each of its own devices' bundle keys, and they must agree — otherwise no
    /// tag ever matches and sender sync silently stops, exactly as it did before 0.18.0.
    ///
    /// Asserted through the tag rather than the secret: the secret stopped being a value this
    /// process holds when the derivation moved into the core. Same target device, opposite halves
    /// of the pair, same tag — which is the property the receive path actually depends on.
    func testTheTwoHalvesOfThePairProduceTheSameTag() {
        let a = Device(id: "a")
        let b = Device(id: "b")
        XCTAssertEqual(
            SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id,
                                    ourIdentityPrivateKey: a.priv, peerIdentityPublicKey: b.pub),
            SenderSyncDeviceTag.tag(baseMessageId: base, targetDeviceId: b.id,
                                    ourIdentityPrivateKey: b.priv, peerIdentityPublicKey: a.pub)
        )
    }

    // MARK: - Recovering on a device that has never sent anything

    /// The state every freshly linked device was in: own devices were known only from a cache the
    /// send path filled, so a device that had linked and not yet sent had none. The candidate list
    /// was the plain `userId` alone, which names no device, so no bundle could be fetched and no
    /// session established — and the loop returned having logged nothing.
    ///
    /// Mutation: `return false` — the refresh never fires and a linked device keeps dropping every
    /// copy in silence, which is what the stand caught on 2026-08-17.
    func testCandidateListWithNoDeviceIdNeedsARefresh() {
        XCTAssertTrue(SenderSyncRecovery.needsOwnDeviceRefresh(
            candidates: ["289b95ca-8260-4b99-a79a-acaba5681b71"]
        ))
        XCTAssertTrue(SenderSyncRecovery.needsOwnDeviceRefresh(candidates: []))
    }

    /// Once a sibling is known the list can recover by itself, and the receive path must not reach
    /// for the network while routing an incoming message.
    ///
    /// Mutation: `return true` — every SENDER_SYNC copy triggers a bundle fetch.
    func testCandidateListNamingADeviceDoesNot() {
        // A per-device candidate is the bare device id since the addressing flip; it used to be
        // `<userId>:<deviceId>`, and this asked whether any candidate contained a colon.
        XCTAssertFalse(SenderSyncRecovery.needsOwnDeviceRefresh(candidates: [
            "289b95ca-8260-4b99-a79a-acaba5681b71",
            "37617f2c0617c888fa4750e0799c49ff",
        ]))
    }

    /// Malformed key material yields no tag rather than a guess. A best-effort tag would be
    /// indistinguishable on the wire from a correct one and would address nobody.
    func testMalformedKeyMaterialYieldsNoTag() {
        let a = Device(id: "a")
        XCTAssertNil(SenderSyncDeviceTag.tag(
            baseMessageId: base, targetDeviceId: a.id,
            ourIdentityPrivateKey: Data([0x01]), peerIdentityPublicKey: a.pub))
        XCTAssertNil(SenderSyncDeviceTag.tag(
            baseMessageId: base, targetDeviceId: a.id,
            ourIdentityPrivateKey: a.priv, peerIdentityPublicKey: Data()))
    }
}
