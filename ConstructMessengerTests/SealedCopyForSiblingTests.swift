import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

/// A sealed copy addressed to one of our other devices is expected, not broken.
///
/// `SealedInner.recipient_device` has been written by the sender since §A.0 and read by nobody.
/// That missing consumer had a cost: while `MSG_MAILBOX_USER_WRITE=1` every device receives the
/// whole account stream, so each sibling's copy reached the unseal, failed — it is sealed to a key
/// this device does not have — and was handled as a *broken* message: deferred for a redelivery
/// that cannot succeed, holding the stream cursor, triggering a bundle-key refresh, and counted
/// against `stealth_unseal_failure`, one of the release-gate numbers. On a multi-device account
/// that is one per message per sibling.
final class SealedCopyForSiblingTests: XCTestCase {

    private func inner(recipientDevice: String) -> Data {
        var msg = Shared_Proto_Core_V1_SealedInner()
        msg.recipientDevice = recipientDevice
        return (try? msg.serializedData()) ?? Data()
    }

    /// **The case this exists for.** The copy names a sibling, so it is not ours to open.
    func testACopyNamingAnotherDeviceIsRecognised() {
        XCTAssertEqual(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: inner(recipientDevice: "device-b"),
            ourDeviceId: "device-a"
        ), "device-b", "the id is the answer: which device it was for is the whole diagnostic")
    }

    /// Our own copy is ours. Answering otherwise would drop every sealed message we receive —
    /// the most expensive possible mistake here, which is why it is asserted directly.
    func testOurOwnCopyIsNotAMismatch() {
        XCTAssertNil(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: inner(recipientDevice: "device-a"),
            ourDeviceId: "device-a"
        ))
    }

    /// An empty `recipient_device` means the sender predates the field. Unknown is not "not ours":
    /// the ordinary path must still report the failure it would have reported.
    func testAnAbsentRecipientDeviceIsNotAMismatch() {
        XCTAssertNil(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: inner(recipientDevice: ""),
            ourDeviceId: "device-a"
        ))
    }

    /// An unreadable local identity — a locked or unreadable Keychain — means we cannot tell.
    /// Guessing here would drop real messages during exactly the window where the device is
    /// least able to recover them.
    func testAnUnknownLocalIdentityIsNotAMismatch() {
        XCTAssertNil(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: inner(recipientDevice: "device-b"),
            ourDeviceId: ""
        ))
    }

    /// A `SealedInner` we cannot parse is the corruption the normal failure path exists to report,
    /// so it must reach that path rather than being silently dropped as a sibling's.
    func testUnparseableBytesAreNotAMismatch() {
        XCTAssertNil(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: Data([0xff, 0xff, 0xff, 0xff]),
            ourDeviceId: "device-a"
        ))
    }

    /// Empty bytes parse to an empty message, which has no recipient device — unknown, not ours.
    func testEmptyBytesAreNotAMismatch() {
        XCTAssertNil(StealthSenderService.otherDeviceAddressed(
            sealedInnerBytes: Data(),
            ourDeviceId: "device-a"
        ))
    }

    // MARK: - Whose device

    /// The case the old `Bool` could not express, and the reason this run's diagnosis cost six
    /// passes of reverse-tracing: a copy for a device of our own account is an expected duplicate
    /// of the account-wide stream, and a copy for a device that is not ours at all is the relay
    /// writing into the wrong mailbox. Both are dropped; only one is a defect.
    func testASiblingAndAStrangerAreDifferentAnswers() {
        XCTAssertEqual(
            StealthSenderService.classifyOtherDevice("device-b", ourDeviceIds: ["device-a", "device-b"]),
            .sibling
        )
        XCTAssertEqual(
            StealthSenderService.classifyOtherDevice("device-z", ourDeviceIds: ["device-a", "device-b"]),
            .foreign
        )
    }

    /// **The trap this exists to avoid.** An empty own-device set is a cold cache, not proof that
    /// the device is a stranger's. Reporting `.foreign` from it would turn every sibling copy
    /// received before the first fan-out into a fabricated routing defect — the same mistake as
    /// reading an absent Prometheus series as a zero, which the server-side counter for this very
    /// gate still makes.
    func testAnUnknownOwnSetIsNotAForeignDevice() {
        XCTAssertEqual(
            StealthSenderService.classifyOtherDevice("device-b", ourDeviceIds: []),
            .unverified
        )
    }

    /// Our own id inside the set changes nothing: the caller only reaches here for a device that
    /// is already known not to be this one, and the classification must not depend on whether the
    /// caller remembered to filter itself out.
    func testOurOwnIdInTheSetDoesNotChangeTheVerdict() {
        XCTAssertEqual(
            StealthSenderService.classifyOtherDevice("device-b", ourDeviceIds: ["device-a", "device-b"]),
            .sibling
        )
        XCTAssertEqual(
            StealthSenderService.classifyOtherDevice("device-z", ourDeviceIds: ["device-a"]),
            .foreign
        )
    }
}
