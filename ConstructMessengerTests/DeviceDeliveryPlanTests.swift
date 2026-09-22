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

    /// The recipient side of the plan is built from the local device set, not from bundles.
    private func device(_ deviceId: String) -> PlannedRecipientDevice {
        PlannedRecipientDevice(bundle(deviceId))
    }

    // MARK: - Who is a target

    /// The ordinary case: the person we write to has two devices, we have one replica.
    func testEveryDeviceOnBothSidesGetsACopy() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [device("r1"), device("r2")],
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
                recipientDevices: [device("r1")],
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
            recipientDevices: [device("me"), device("mine2")],
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
            recipientDevices: [device("r1")],
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
            recipientDevices: [device("r1")],
            ownDevices: [bundle("me"), bundle("mine2")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.first?.audience, .recipient)
        XCTAssertEqual(targets.last?.audience, .ownReplica)
    }

    /// There is no primary send, so there is no device the plan leaves out for it: every device
    /// of the recipient is a target, in the order the set gives them.
    ///
    /// Until 2026-09-22 the plan subtracted `primarySendCovered` — the device the ordinary send
    /// had reached by the pinned key — which is what made one of the recipient's devices a
    /// different kind of recipient from the others. The core still takes the parameter; this
    /// app hands it the empty string, and the guard below pins that nothing passes anything else.
    ///
    /// Mutation: pass a device id as `primarySendCovered` again — this reddens.
    func testEveryRecipientDeviceIsPlannedAndNoneIsPrivileged() {
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [device("r1"), device("r2"), device("r3")],
            ownDevices: [bundle("me")],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.map(\.deviceId), ["r1", "r2", "r3"])
    }

    /// A target from the local set carries the device's identity key and no bundle; one from a
    /// fetch carries both. The sender opens a session from the bundle only when it has none, so
    /// a missing bundle is the ordinary shape, not a defect.
    func testALocalDeviceCarriesItsKeyAndNoBundle() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let targets = DeviceDeliveryPlan.targets(
            recipientDevices: [PlannedRecipientDevice(deviceId: "r1", identityPublic: key), device("r2")],
            ownDevices: [],
            ourDeviceId: "me",
            recipientIsSelf: false
        )
        XCTAssertEqual(targets.map(\.deviceId), ["r1", "r2"])
        XCTAssertEqual(targets[0].identityPublic, key)
        XCTAssertNil(targets[0].bundle)
        XCTAssertNotNil(targets[1].bundle)
        XCTAssertEqual(targets[1].identityPublic, targets[1].bundle?.identityPublic)
    }

    /// The source guard for the above: `primarySendCovered:` is passed exactly once in the app,
    /// as the empty string, from the one translation site. A second site, or a value, is the
    /// primary send coming back.
    func testNothingInTheAppNamesACoveredDevice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
        var sites: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "construct_core.swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("primarySendCovered:") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//") else { continue }
                sites.append("\(url.lastPathComponent): \(t)")
            }
        }
        XCTAssertEqual(sites, ["DeviceDeliveryPlan.swift: primarySendCovered: \"\""], "\(sites)")
    }

    // MARK: - Where the device set comes from

    /// The device the peer linked after we pinned their set. Nothing local names it — it has never
    /// written to us — so if the directory's answer does not enter the plan, it never gets a copy.
    ///
    /// Mutation: return `local` unconditionally — this reddens.
    func testADeviceOnlyTheDirectoryKnowsIsPlanned() {
        let known = device("r1")
        let newlyLinked = bundle("r2")
        let merged = PlannedRecipientDevice.merge(local: [known], directory: [newlyLinked])
        XCTAssertEqual(merged.map(\.deviceId), ["r1", "r2"])
    }

    /// A device we hold and the directory does not name is **kept**. The answer is narrowed by the
    /// request and again by this client dropping a device whose hybrid-PQ bundle failed to verify;
    /// that device is alive and we may hold a live session with it. Only `active_devices` removes
    /// a device, in `reconcileDevices`.
    ///
    /// Mutation: build the result from `directory` alone — this reddens.
    func testADeviceTheDirectoryDidNotNameIsKept() {
        // A row as the send path builds it from `PeerDevice`: a key, no bundle.
        let held = PlannedRecipientDevice(deviceId: "r1", identityPublic: Data(repeating: 7, count: 32))
        let merged = PlannedRecipientDevice.merge(local: [held], directory: [bundle("r2")])
        XCTAssertEqual(merged.map(\.deviceId), ["r1", "r2"])
        XCTAssertNil(merged.first { $0.deviceId == "r1" }?.bundle, "the local row is carried as it is")
    }

    /// Where both name a device, the directory entry wins — it carries the bundle, and a caller
    /// with one opens a session without a second fetch.
    func testTheDirectoryEntryCarriesTheBundleForADeviceWeAlreadyHold() {
        let merged = PlannedRecipientDevice.merge(local: [device("r1")], directory: [bundle("r1")])
        XCTAssertEqual(merged.map(\.deviceId), ["r1"])
        XCTAssertNotNil(merged.first?.bundle)
    }

    /// No answer from the key server is not an empty device set: it is no answer. Planning from
    /// nothing would drop every copy to a peer whose bundles are momentarily unavailable.
    func testAnEmptyDirectoryLeavesTheLocalSetAlone() {
        let merged = PlannedRecipientDevice.merge(local: [device("r1"), device("r2")], directory: [])
        XCTAssertEqual(merged.map(\.deviceId), ["r1", "r2"])
    }

    /// First contact: nothing local, and the plan is the account's devices — all of them.
    func testFirstContactPlansEveryDeviceTheDirectoryNames() {
        let merged = PlannedRecipientDevice.merge(local: [], directory: [bundle("r1"), bundle("r2")])
        XCTAssertEqual(merged.map(\.deviceId), ["r1", "r2"])
        XCTAssertTrue(merged.allSatisfy { $0.bundle != nil })
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
