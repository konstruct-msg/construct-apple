//
//  DeviceDeliveryPlanTests.swift
//  ConstructMessengerTests
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class DeviceDeliveryPlanTests: XCTestCase {

    private let base = "34f009c9-caa1-41a3-964e-40af9f3129a7"

    /// Only `deviceId` and `identityPublic` matter to the plan; the rest of a bundle is what the
    /// session layer needs and is filled with whatever decodes.
    private func bundle(_ deviceId: String) -> DeviceBundleData {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return DeviceBundleData(
            deviceId: deviceId,
            bundle: PublicKeyBundleData(
                userId: "e7a4e3d2-0000-4000-8000-000000000001",
                username: "",
                identityPublic: key.publicKey.rawRepresentation,
                signedPrekeyPublic: Data(repeating: 0, count: 32),
                signature: Data(repeating: 0, count: 64),
                verifyingKey: Data(repeating: 0, count: 32),
                suiteId: 1,
                spkUploadedAt: 0,
                spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0,
                kyberSpkRotationEpoch: 0
            ),
            platform: .ios
        )
    }

    // MARK: - Who is a target

    /// The ordinary case: the person we write to has two devices, we have one replica.
    func testEveryDeviceOnBothSidesGetsACopy() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [bundle("r1"), bundle("r2")],
            ownDevices: [bundle("me"), bundle("mine2")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.map(\.deviceId), ["r1", "r2", "mine2"])
        XCTAssertEqual(
            targets.map(\.audience),
            [.recipient, .recipient, .ownReplica]
        )
    }

    /// The sending device is never a target. Delivery hands us our own copy back regardless, so
    /// planning one means this device tries to open a message it just encrypted — and on
    /// `messageNumber == 0` that takes the recovery path into a bundle fetch.
    ///
    /// Mutation: drop the `$0.deviceId != ourDeviceId` filter — this reddens.
    func testOurOwnSendingDeviceIsNotATarget() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [],
            ownDevices: [bundle("me"), bundle("mine2")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.map(\.deviceId), ["mine2"])
    }

    /// Without our own device id we cannot tell ourselves from our replicas, and a copy addressed
    /// to this device is worse than no copy: it is guaranteed session churn on every send.
    ///
    /// Mutation: plan all own devices when the id is missing — this reddens.
    func testNoOwnDeviceIdMeansNoReplicaCopies() {
        for ourId in [nil, ""] {
            let targets = DeviceDeliveryPlan.targets(
                recipientDevices: [bundle("r1")],
                ownDevices: [bundle("me"), bundle("mine2")],
                ourDeviceId: ourId,
                recipientIsSelf: false
            )
            XCTAssertEqual(targets.map(\.deviceId), ["r1"], "ourDeviceId = \(String(describing: ourId))")
        }
    }

    /// A note to self: the recipient's devices *are* our devices. Planning both audiences would
    /// send every replica two ciphertexts of one message, and the transcript would show it twice.
    ///
    /// Mutation: drop the `recipientIsSelf` early return — the replica appears twice, this reddens.
    func testWritingToOurselvesPlansEachReplicaOnce() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [bundle("me"), bundle("mine2")],
            ownDevices: [bundle("me"), bundle("mine2")],
            ourDeviceId: "me",
            recipientIsSelf: true
        )
        XCTAssertEqual(targets.map(\.deviceId), ["mine2"])
        XCTAssertEqual(targets.map(\.audience), [.ownReplica])
    }

    /// A single-device account on both sides still plans the one real target.
    func testASingleDeviceRecipientIsStillATarget() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [bundle("r1")],
            ownDevices: [bundle("me")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.map(\.deviceId), ["r1"])
    }

    /// Order is part of the contract: a retry must rebuild the same wire ids, and a test that
    /// asserts on a set cannot notice when it stops.
    func testRecipientCopiesComeBeforeOwnReplicas() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [bundle("r1")],
            ownDevices: [bundle("me"), bundle("mine2")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.first?.audience, .recipient)
        XCTAssertEqual(targets.last?.audience, .ownReplica)
    }

    // MARK: - What the copy says out loud

    /// A single-chunk copy carries no chunk suffix; a multi-chunk one carries it after the tag, so
    /// the tag stays readable from whichever chunk arrives first.
    func testWireIdCarriesTheChunkIndexOnlyWhenThereAreSeveral() {
        XCTAssertEqual(
            DeviceDeliveryPlan.wireId(baseMessageId: base, tag: "13819e444aa59d15",
                                      audience: .ownReplica, chunkIndex: 0, chunkCount: 1),
            "\(base)-ss-13819e444aa59d15"
        )
        XCTAssertEqual(
            DeviceDeliveryPlan.wireId(baseMessageId: base, tag: "13819e444aa59d15",
                                      audience: .ownReplica, chunkIndex: 2, chunkCount: 5),
            "\(base)-ss-13819e444aa59d15-c2"
        )
    }

    /// The wire id a copy for the recipient's other device travels under.
    ///
    /// Mutation: put the device id where the tag goes — the relay can read it again, and the
    /// assertion below on the plain id reddens. That is exactly what this path did until
    /// 2026-08-25, while the neighbouring path had been fixed eight days earlier.
    func testARecipientCopyDoesNotNameTheDeviceItIsFor() {
        let deviceId = "b3ed60ab5d0ef2c01f292a40bcdc3465"
        let tag = "13819e444aa59d15"
        let id = DeviceDeliveryPlan.wireId(baseMessageId: base, tag: tag,
                                           audience: .recipient, chunkIndex: 0, chunkCount: 1)
        XCTAssertFalse(id.contains(deviceId))
        XCTAssertFalse(id.contains(String(deviceId.prefix(8))))
        XCTAssertTrue(id.hasSuffix(tag))
    }

    /// `DeviceCopyWireId` reads the tag back out of the id the plan writes. The two are separate
    /// files and one is the only reader of the other, so a change to either shape must break here
    /// rather than in a stand run.
    func testTheWireIdRoundTripsThroughTheReader() {
        let tag = "13819e444aa59d15"
        for chunk in 0..<3 {
            let id = DeviceDeliveryPlan.wireId(baseMessageId: base, tag: tag,
                                               audience: .ownReplica, chunkIndex: chunk, chunkCount: 3)
            XCTAssertEqual(DeviceCopyWireId.targetDeviceTag(of: id), tag)
            XCTAssertEqual(DeviceCopyWireId.baseId(of: id), base)
        }
    }
}
