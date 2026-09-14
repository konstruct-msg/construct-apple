import XCTest
import CoreData
@testable import Construct_Messenger

/// §B.4: the session heartbeat is addressed to an account and sealed like everything else.
///
/// It was neither. `sendSessionHeartbeat` is reached from `getAllSessionContactIds()` and from
/// the core's `.sendHeartbeat` action, and both hand it a `CryptoDeviceId`. That id went straight
/// into `Envelope.recipient`, where the server parses a UUID: it got none, `fetch_recipient_device_ids`
/// returned an empty list, and the envelope was written to a stream keyed by 32 hex characters
/// that nothing subscribes to. Accepted, acknowledged, delivered nowhere.
///
/// Two failures stacked, and each hid the other. A liveness probe that never arrives looks exactly
/// like a peer that has nothing to say, so nothing reported it; and the send was also the last
/// unsealed peer-directed envelope, naming (sender, recipient) in the clear on a timer — which is
/// a cleaner correlation signal than ordinary traffic, not a weaker one, precisely because it only
/// fires when a session has been silent for hours.
///
/// These tests pin the seam the fix goes through. The send itself needs a network and is not
/// reachable here; what is reachable is the translation it was missing.
final class HeartbeatAddressingTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    @discardableResult
    private func makeContact(id: String, key: Data) -> User {
        let user = User(context: context)
        user.id = id
        user.knownIdentityKey = key
        try? context.save()
        return user
    }

    func testResolvesADeviceBackToItsAccountAndKey() throws {
        let key = Data((0..<32).map { UInt8($0 &+ 7) })
        let accountId = "14f28d31-0000-0000-0000-0000000000aa"
        makeContact(id: accountId, key: key)

        let device = try XCTUnwrap(SessionAddressing.cryptoIdentity(ofIdentityKey: key))
        let peer = try XCTUnwrap(SessionAddressing.peer(ofDevice: device, in: context))

        XCTAssertEqual(peer.accountId, accountId)
        XCTAssertEqual(peer.identityKey, key)
    }

    /// The two halves come from one row on purpose. A key belonging to one contact and an account
    /// id belonging to another would address the envelope to one person and seal it to another —
    /// undeliverable, and undetectable from either side.
    ///
    /// **Both directions are asserted in one test deliberately.** Written as a single lookup it
    /// passed against an implementation that ignored the device entirely and returned whichever
    /// row the fetch happened to hand back first — the predicate has no sort descriptor, so that
    /// was luck, and a test that passes by luck is one that will also fail by it. Asked about two
    /// devices, a first-match implementation can satisfy at most one.
    func testTheAccountAndTheKeyComeFromTheSameContact() throws {
        let keyA = Data(repeating: 0x11, count: 32)
        let keyB = Data(repeating: 0x22, count: 32)
        let accountA = "14f28d31-0000-0000-0000-0000000000aa"
        let accountB = "14f28d31-0000-0000-0000-0000000000bb"
        makeContact(id: accountA, key: keyA)
        makeContact(id: accountB, key: keyB)

        let deviceA = try XCTUnwrap(SessionAddressing.cryptoIdentity(ofIdentityKey: keyA))
        let deviceB = try XCTUnwrap(SessionAddressing.cryptoIdentity(ofIdentityKey: keyB))
        let peerA = try XCTUnwrap(SessionAddressing.peer(ofDevice: deviceA, in: context))
        let peerB = try XCTUnwrap(SessionAddressing.peer(ofDevice: deviceB, in: context))

        XCTAssertEqual(peerA.accountId, accountA)
        XCTAssertEqual(peerA.identityKey, keyA)
        XCTAssertEqual(peerB.accountId, accountB)
        XCTAssertEqual(peerB.identityKey, keyB)
    }

    /// No pinned key for that device — the heartbeat must be skipped, not sent to a guess. There
    /// is nothing to seal to and no account to address, and a probe is safe to omit.
    func testAnUnknownDeviceResolvesToNothing() {
        makeContact(id: "14f28d31-0000-0000-0000-0000000000aa", key: Data(repeating: 0x11, count: 32))
        let stranger = String(repeating: "ab", count: 16)

        XCTAssertNil(SessionAddressing.peer(ofDevice: stranger, in: context))
    }

    /// An account id must never resolve to a peer. What this pins is the answer, not the route to
    /// it: removing the `isCryptoIdentity` guard leaves this test green, because a 36-char UUID
    /// also fails the key comparison further down. The guard is an early exit worth keeping and
    /// not a rule this test proves — said here because the first version of this comment claimed
    /// otherwise, and a comment that promises more than its test checks is the same reassurance
    /// as a test that cannot fail.
    func testAnAccountIdIsNotADevice() {
        let accountId = "14f28d31-0000-0000-0000-0000000000aa"
        makeContact(id: accountId, key: Data(repeating: 0x11, count: 32))

        XCTAssertNil(SessionAddressing.peer(ofDevice: accountId, in: context))
    }
}
