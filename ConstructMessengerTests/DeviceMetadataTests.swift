import XCTest
@testable import Construct_Messenger

/// A device's name and platform, sealed to its own account's devices.
///
/// Migration `013_privacy_simplify_devices.sql` dropped both from the server's table, naming them
/// device fingerprinting and an OS leak. What that cost was the device list: with nothing to show
/// but an id, two links of one Mac are two identical rows. 2026-09-03 — a Desktop that had been
/// revoked kept running for a day, and its handshakes archived the sibling's session on every peer
/// it talked to, 41 times out of 42.
final class DeviceMetadataTests: XCTestCase {

    private func metadata(_ name: String) -> Shared_Proto_Services_V1_DeviceMetadata {
        var m = Shared_Proto_Services_V1_DeviceMetadata()
        m.deviceName = name
        m.platform = .desktop
        return m
    }

    /// A device: its core, which holds the identity key and opens with it, and the public half.
    private func deviceKeys() throws -> (core: OrchestratorCore, publicKey: Data) {
        let core = try makeTestDevice().core
        return (core, try core.getRegistrationBundleFields().identityPublic)
    }

    private func open(_ blob: Data, as device: (core: OrchestratorCore, publicKey: Data)) -> Shared_Proto_Services_V1_DeviceMetadata? {
        DeviceMetadataService.open(blob, openingWith: device.core.openSealedToDevice(sealedBox:))
    }

    // MARK: - The account reads it, nobody else does

    /// **The property the whole design rests on.** Every device of the account opens the blob;
    /// a key outside it opens nothing.
    func testEveryDeviceOfTheAccountOpensItAndAStrangerDoesNot() throws {
        let devices = [try deviceKeys(), try deviceKeys(), try deviceKeys()]
        let stranger = try deviceKeys()

        let blob = DeviceMetadataService.seal(
            metadata("work laptop"),
            toIdentityKeys: devices.map(\.publicKey)
        )
        XCTAssertNotNil(blob)

        for (i, device) in devices.enumerated() {
            let opened = open(blob!, as: device)
            XCTAssertEqual(opened?.deviceName, "work laptop", "device \(i) could not read its own copy")
            XCTAssertEqual(opened?.platform, .desktop)
        }

        XCTAssertNil(
            open(blob!, as: stranger),
            "a key outside the account opened the blob"
        )
    }

    /// A device linked after the last re-seal has no copy. That is an ordinary state, not a
    /// failure: the row falls back to the short id, which identifies it either way.
    func testADeviceWithNoCopyReadsNothingRatherThanFailing() throws {
        let sealedFor = try deviceKeys()
        let newcomer = try deviceKeys()
        let blob = DeviceMetadataService.seal(metadata("Mac"), toIdentityKeys: [sealedFor.publicKey])!
        XCTAssertNil(open(blob, as: newcomer))
    }

    /// **Not a blob with no copies.** An empty key set is a cold cache or a failed fetch, and
    /// publishing an empty blob would replace a good one with nothing — clearing this device's
    /// name on every sibling because we momentarily could not list them.
    func testAnEmptyDeviceSetSealsNothing() {
        XCTAssertNil(DeviceMetadataService.seal(metadata("Mac"), toIdentityKeys: []))
    }

    /// Garbage in the field is a `nil`, not a crash: the blob comes off the network, and the read
    /// path runs on a screen a person is looking at.
    func testUnreadableInputIsNil() throws {
        let ours = try deviceKeys()
        XCTAssertNil(open(Data([0xff, 0xff, 0xff]), as: ours))
        XCTAssertNil(open(Data(), as: ours))
    }

    // MARK: - When to re-publish

    /// A device added: it has no copy until we re-seal, which is the visible symptom.
    func testADeviceAddedNeedsAPublish() {
        XCTAssertTrue(DeviceMetadataService.needsPublish(currentDeviceIds: ["a", "b"], lastPublishedFor: ["a"]))
    }

    /// A device removed: it can still read until we re-seal, which is the invisible one — and the
    /// reason this is not "publish when a device appears".
    func testADeviceRemovedNeedsAPublishToo() {
        XCTAssertTrue(DeviceMetadataService.needsPublish(currentDeviceIds: ["a"], lastPublishedFor: ["a", "b"]))
    }

    func testAnUnchangedSetNeedsNothing() {
        XCTAssertFalse(DeviceMetadataService.needsPublish(currentDeviceIds: ["b", "a"], lastPublishedFor: ["a", "b"]))
    }

    /// An unknown set publishes nothing. Sealing to an empty set is already refused above; this
    /// stops the caller from even reaching that, so a failed device fetch cannot look like an
    /// account that lost all its devices.
    func testAnUnknownSetPublishesNothing() {
        XCTAssertFalse(DeviceMetadataService.needsPublish(currentDeviceIds: [], lastPublishedFor: ["a"]))
        XCTAssertFalse(DeviceMetadataService.needsPublish(currentDeviceIds: [], lastPublishedFor: []))
    }
}
