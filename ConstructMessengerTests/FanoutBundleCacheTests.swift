import XCTest
@testable import Construct_Messenger

/// The fan-out used to fetch a recipient's bundles on every message and spend a one-time pre-key
/// each time. Both were invisible on a single-device peer, because there is no fan-out at all.
///
/// 2026-09-03, one minute of an ordinary conversation with a two-device peer: five fan-outs and
/// three session fetches, then
///
///     MultiDevice fan-out skipped for ffeeddc6… — reason=bundle_fetch_failed
///     believed=2: resourceExhausted: "Too many bundle requests"
///
/// twice. The peer's second device silently missed those messages. Typing slowly worked; typing
/// normally did not — which is what "the behaviour is completely unpredictable" was.
final class FanoutBundleCacheTests: XCTestCase {

    // MARK: - Is the cached set still the peer's set

    func testAnUnchangedSetIsStillCurrent() {
        XCTAssertTrue(
            MultiDeviceSendCoordinator.cachedSetStillMatches(cached: ["a", "b"], known: ["b", "a"]),
            "order is not part of the answer — a set is"
        )
    }

    /// A device linked or revoked since the entry was built. `PeerDevice` is rewritten from the
    /// `active_devices` of every bundles response the app makes, so this fires without a fetch of
    /// our own — which is what makes the TTL a backstop rather than the mechanism.
    func testAChangedSetIsNotCurrent() {
        XCTAssertFalse(MultiDeviceSendCoordinator.cachedSetStillMatches(cached: ["a"], known: ["a", "b"]))
        XCTAssertFalse(MultiDeviceSendCoordinator.cachedSetStillMatches(cached: ["a", "b"], known: ["a"]))
        XCTAssertFalse(MultiDeviceSendCoordinator.cachedSetStillMatches(cached: ["a"], known: ["b"]))
    }

    /// **The trap.** No `PeerDevice` rows is no evidence, not "they have no devices". Reading it
    /// as a mismatch would drop the entry for every peer we have never fetched devices for —
    /// exactly the peer a cache exists for — and restore one fetch per message.
    func testAnUnknownSetLeavesTheDecisionToTheTTL() {
        XCTAssertTrue(MultiDeviceSendCoordinator.cachedSetStillMatches(cached: ["a", "b"], known: []))
    }

    // MARK: - Does the fetch have to spend a pre-key

    func testADeviceWithNoSessionNeedsOne() {
        XCTAssertTrue(
            MultiDeviceSendCoordinator.needsOneTimePrekey(knownDeviceIds: ["a", "b"]) { $0 == "a" }
        )
    }

    /// The case that was paying on every message: sessions already exist with every device, so
    /// nothing will run X3DH and nothing should be spent.
    func testDevicesWeAlreadyHaveSessionsWithNeedNone() {
        XCTAssertFalse(
            MultiDeviceSendCoordinator.needsOneTimePrekey(knownDeviceIds: ["a", "b"]) { _ in true }
        )
    }

    /// Unknown is "yes", and deliberately: the two errors are not symmetrical. Spending a pre-key
    /// we did not need costs a pre-key; not spending one we did costs the message, because the
    /// fan-out then cannot open a session at all.
    func testAnUnknownRecipientSpendsOne() {
        XCTAssertTrue(
            MultiDeviceSendCoordinator.needsOneTimePrekey(knownDeviceIds: []) { _ in true }
        )
    }
}
