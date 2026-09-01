import XCTest
import CoreData
@testable import Construct_Messenger

/// The seam as an object: a peer named in both spaces, so a caller cannot pick the wrong one by
/// accident because there is no bare id left to pick.
///
/// Devices 2026-09-01. `MessageRouterDelegate` carried one `String` called `userId`, fed from two
/// sources — the envelope (an account) and a Rust orchestrator action (a device). On the
/// device-space paths the recovery ran:
///
///     SESSION_STATE[proactive_init_start]: userId=651e765c…
///     SESSION_STATE[fetch_bundle_failed]: attempt=1/3 … notFound: "User or device not found"
///     SESSION_STATE[fetch_bundle_failed]: attempt=2/3 … notFound: "User or device not found"
///     SESSION_STATE[fetch_bundle_failed]: attempt=3/3 … notFound: "User or device not found"
///     SESSION_STATE[proactive_init_failed]: userId=651e765c…
///
/// eight times in one session, on a **single-device** peer. The server is right: `651e765c…` is a
/// device. Half of that peer's divergences were therefore unrecoverable, silently.
final class PeerAddressTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        context = nil
        super.tearDown()
    }

    private let accountA = "14f28d31-0000-0000-0000-0000000000aa"
    private let accountB = "14f28d31-0000-0000-0000-0000000000bb"

    /// A key and the device id that is a function of it.
    private func device(_ byte: UInt8) -> (deviceId: String, identityKey: Data) {
        let key = Data(repeating: byte, count: 32)
        return (deviceId: deriveDeviceId(identityPublicKey: [UInt8](key)), identityKey: key)
    }

    @discardableResult
    private func makeContact(id: String, key: Data) -> User {
        let user = User(context: context)
        user.id = id
        user.knownIdentityKey = key
        try? context.save()
        return user
    }

    // MARK: - Construction

    func testAnEmptyDeviceIsNoDevice() {
        // `""` reads as a named device at every `!isEmpty` guard downstream and as an unnamed one
        // at every `!= nil`. Normalise once, at construction, so the two never disagree.
        XCTAssertNil(PeerAddress(account: accountA, device: "").device)
        XCTAssertNil(PeerAddress(account: accountA, device: nil).device)
        XCTAssertNil(PeerAddress.account(accountA).device)
    }

    func testBothHalvesSurviveConstruction() {
        let d = device(0x11)
        let peer = PeerAddress(account: accountA, device: d.deviceId)
        XCTAssertEqual(peer.account, accountA)
        XCTAssertEqual(peer.device, d.deviceId)
    }

    func testDescriptionShowsBothHalves() {
        let d = device(0x11)
        XCTAssertEqual(
            PeerAddress(account: accountA, device: d.deviceId).description,
            "\(accountA.prefix(8))…/\(d.deviceId.prefix(8))…"
        )
        // The unnamed half is stated, not omitted: a log line that silently drops it reads
        // identically to one where a device was named, which is how the account slot got a
        // device id into it for a fortnight without anyone seeing the difference.
        XCTAssertEqual(PeerAddress.account(accountA).description, "\(accountA.prefix(8))…/—")
    }

    // MARK: - deviceOrPinned

    /// **The property the recovery path rests on.** When the core names the device that diverged,
    /// that device must survive the trip — not be replaced by whichever one `User.knownIdentityKey`
    /// happens to hold. On a multi-device peer they are different devices, and substituting the
    /// pinned one archives a healthy session while leaving the broken one in place.
    func testANamedDeviceIsNeverReplacedByThePinnedOne() {
        let pinned = device(0x11)
        let diverged = device(0x22)
        makeContact(id: accountA, key: pinned.identityKey)
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { [pinned] id in
            id == self.accountA ? pinned.identityKey : nil
        }

        XCTAssertEqual(
            SessionAddressing.contactId(forPeer: accountA), pinned.deviceId,
            "pre-condition: the account resolves to the pinned device, which is NOT the diverged one"
        )
        XCTAssertEqual(
            PeerAddress(account: accountA, device: diverged.deviceId).deviceOrPinned(),
            diverged.deviceId,
            "a named device is the answer; nothing re-resolves it"
        )
    }

    func testAnUnnamedDeviceFallsBackToThePinnedOne() {
        let pinned = device(0x11)
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { [pinned] id in
            id == self.accountA ? pinned.identityKey : nil
        }
        XCTAssertEqual(PeerAddress.account(accountA).deviceOrPinned(), pinned.deviceId)
    }

    func testAnUnnameablePeerHasNoDevice() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { _ in nil }
        // Not an error: the same state as "we have never pinned this contact's key", in which no
        // session with them exists. Callers must decline, never substitute the account id.
        XCTAssertNil(PeerAddress.account(accountA).deviceOrPinned())
    }

    // MARK: - resolving(device:)

    func testResolvingNamesTheAccountAndKeepsTheDevice() {
        let d = device(0x11)
        makeContact(id: accountA, key: d.identityKey)

        let peer = PeerAddress.resolving(device: d.deviceId, in: context)
        XCTAssertEqual(peer?.account, accountA)
        XCTAssertEqual(peer?.device, d.deviceId, "the device that was asked about is the device named")
    }

    func testResolvingASecondDeviceOnceRecorded() {
        let pinned = device(0x11)
        let second = device(0x22)
        makeContact(id: accountA, key: pinned.identityKey)

        XCTAssertNil(
            PeerAddress.resolving(device: second.deviceId, in: context),
            "pre-condition: an unrecorded second device is attributable to nobody"
        )
        SessionAddressing.recordDevices(
            [(deviceId: second.deviceId, identityKey: second.identityKey)],
            ofPeer: accountA,
            in: context
        )
        XCTAssertEqual(PeerAddress.resolving(device: second.deviceId, in: context)?.account, accountA)
    }

    /// The failure mode this type exists to make impossible: an unresolvable device must not
    /// become an account. `nil` is the honest answer; a `PeerAddress(account: deviceId)` would be
    /// the original defect wearing the new type.
    func testAnUnknownDeviceNeverBecomesAnAccount() {
        let unknown = device(0x33)
        XCTAssertNil(PeerAddress.resolving(device: unknown.deviceId, in: context))
    }

    func testResolvingRefusesAnAccountId() {
        makeContact(id: accountA, key: device(0x11).identityKey)
        // An account id is not a device id, and reading the seam backwards from one is a caller
        // that already had the answer. `peer(ofDevice:)` declines it; so does this.
        XCTAssertNil(PeerAddress.resolving(device: accountA, in: context))
        XCTAssertNil(PeerAddress.resolving(device: accountB, in: context))
    }

    // MARK: - The invariant, stated

    /// No `PeerAddress` produced by the two constructors may put a crypto identity in `account`.
    /// This is the whole defect in one line, and it is the shape a reviewer can check by eye at
    /// every call site: `.account(x)` where `x` came from an envelope, `PeerAddress(account:
    /// otherUserId, device:)` where the device came from the core.
    func testTheAccountSlotNeverHoldsADeviceId() {
        let d = device(0x11)
        makeContact(id: accountA, key: d.identityKey)

        let addresses = [
            PeerAddress.account(accountA),
            PeerAddress(account: accountA, device: d.deviceId),
            PeerAddress.resolving(device: d.deviceId, in: context)
        ].compactMap { $0 }

        XCTAssertEqual(addresses.count, 3, "resolving must have answered, or this test reads nothing")
        for address in addresses {
            XCTAssertFalse(
                SessionAddressing.isCryptoIdentity(address.account),
                "\(address) puts a 32-hex device id where the key service reads an account UUID"
            )
        }
    }
}
