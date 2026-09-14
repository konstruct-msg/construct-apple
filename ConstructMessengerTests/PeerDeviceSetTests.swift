import XCTest
import CoreData
@testable import Construct_Messenger

/// §B: a peer is a set of devices, not one key.
///
/// `User.knownIdentityKey` is a single `Data` slot per account while delivery goes to N devices.
/// Every store that held per-peer crypto state inherited that slot, so exactly one device of a
/// multi-device peer could be addressed correctly and the rest were unreachable by construction —
/// a Desktop linked 2026-08-30 failed to unseal 155 of 155 envelopes over five hours, every one of
/// them sealed to the iPhone's identity key.
///
/// See `decisions/a-peer-is-a-set-of-devices.md`.
final class PeerDeviceSetTests: XCTestCase {

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

    /// A key and the device id that is a function of it — the only shape a row may hold.
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

    // MARK: - The regression this entity exists for

    /// **The defect, stated as a test.** Before `PeerDevice`, the only way to map a device back to
    /// its account was a scan of `User.knownIdentityKey` — one slot — so a peer's *second* device
    /// resolved to nothing. `sendEndSession` then had no device to name and addressed the account,
    /// which the server fans out to every device of it: a divergence with one device tore down the
    /// healthy sessions of its siblings.
    ///
    /// The pre-condition is asserted first on purpose. Without it this test would pass against an
    /// implementation that resolved the second device by accident through the pinned-key scan, and
    /// would then be pinning luck rather than the set.
    func testASecondDeviceResolvesToItsAccountOnlyOnceRecorded() throws {
        let pinned = device(0x11)
        let second = device(0x22)
        makeContact(id: accountA, key: pinned.identityKey)

        XCTAssertNotNil(
            SessionAddressing.peer(ofDevice: pinned.deviceId, in: context),
            "the pinned device was always resolvable — the scan finds it"
        )
        XCTAssertNil(
            SessionAddressing.peer(ofDevice: second.deviceId, in: context),
            "before recording, a second device has no row and no pinned key: this is the defect"
        )

        SessionAddressing.recordDevices([pinned, second], ofPeer: accountA, in: context)

        let resolved = try XCTUnwrap(SessionAddressing.peer(ofDevice: second.deviceId, in: context))
        XCTAssertEqual(resolved.accountId, accountA)
        XCTAssertEqual(resolved.identityKey, second.identityKey)
    }

    // MARK: - The set

    func testDevicesOfPeerReturnsTheWholeSet() {
        let one = device(0x11)
        let two = device(0x22)
        SessionAddressing.recordDevices([one, two], ofPeer: accountA, in: context)

        let set = SessionAddressing.devices(ofPeer: accountA, in: context)
        XCTAssertEqual(set.map(\.deviceId).sorted(), [one.deviceId, two.deviceId].sorted())
        XCTAssertEqual(Set(set.map(\.identityKey)), [one.identityKey, two.identityKey])
    }

    /// Devices of one account never appear under another. Asked about both accounts in one test,
    /// because an implementation that ignored the predicate and returned every row would satisfy a
    /// single-account assertion.
    func testTheSetIsScopedToItsAccount() {
        let a = device(0x11)
        let b = device(0x22)
        SessionAddressing.recordDevices([a], ofPeer: accountA, in: context)
        SessionAddressing.recordDevices([b], ofPeer: accountB, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId), [a.deviceId])
        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountB, in: context).map(\.deviceId), [b.deviceId])
    }

    /// Empty means "we have never been told", not "this account has no devices". A fetch that
    /// timed out and an account with nothing on it are indistinguishable at the call site, so an
    /// empty answer must not be allowed to overwrite what is already pinned.
    func testAnEmptyAnswerRecordsNothingAndErasesNothing() {
        let one = device(0x11)
        SessionAddressing.recordDevices([one], ofPeer: accountA, in: context)

        SessionAddressing.recordDevices([], ofPeer: accountA, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId), [one.deviceId])
    }

    /// The order is total and stable: `firstSeenAt`, then `deviceId`. Two devices recorded in one
    /// call are written microseconds apart, so without the tiebreak the order of a first fetch is
    /// whatever the store hands back — and a walk whose order differs between runs makes a failure
    /// reproduce on one launch and not the next.
    func testTheSetHasAStableOrder() {
        let one = device(0x11)
        let two = device(0x22)
        SessionAddressing.recordDevices([one, two], ofPeer: accountA, in: context)

        let first = SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId)
        let second = SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
    }

    /// A device recorded earlier keeps its place when the set grows. This is what keeps the device
    /// a single-device peer has always had at the head of the walk — the order the pinned key
    /// produced before this entity existed.
    func testAnEarlierDeviceStaysFirst() {
        let first = device(0x11)
        SessionAddressing.recordDevices([first], ofPeer: accountA, in: context)
        SessionAddressing.recordDevices([first, device(0x22)], ofPeer: accountA, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).first?.deviceId, first.deviceId)
    }

    // MARK: - The translation half

    /// What stays in Swift after the plan moved into the core: `account → devices`, and nothing
    /// else. The core speaks `CryptoDeviceId` only and has no `ServerUserId`, so this translation
    /// cannot live there; the decision over the set — which of these devices a teardown touches —
    /// is `orchestration::teardown_plan` and is tested in Rust, where both clients get the same
    /// answer. See AGENTS.md, "The core decides, this app executes".
    func testAnAccountTranslatesToEveryPinnedDevice() {
        let one = device(0x11)
        let two = device(0x22)
        SessionAddressing.recordDevices([one, two], ofPeer: accountA, in: context)

        let ids = SessionAddressing.deviceIds(ofPeer: accountA, in: context)
        XCTAssertEqual(ids.sorted(), [one.deviceId, two.deviceId].sorted())
    }

    /// A device id is already in the crypto space and passes through as a set of one. The core's
    /// actions hand device ids down, and translating one again must not expand it into the
    /// account's other devices.
    func testADeviceIdTranslatesToItself() {
        let one = device(0x11)
        let two = device(0x22)
        SessionAddressing.recordDevices([one, two], ofPeer: accountA, in: context)

        XCTAssertEqual(SessionAddressing.deviceIds(ofPeer: one.deviceId, in: context), [one.deviceId])
    }

    /// An account we have never fetched bundles for has no set, and the pinned key is then the only
    /// name we hold. This is the single-device case the pin was always right for — and the fallback
    /// must produce a *device*, never the account id it was given.
    func testAnUnfetchedAccountFallsBackToItsPinnedDevice() {
        let pinned = device(0x11)
        makeContact(id: accountA, key: pinned.identityKey)
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { $0 == self.accountA ? pinned.identityKey : nil }

        XCTAssertEqual(SessionAddressing.deviceIds(ofPeer: accountA, in: context), [pinned.deviceId])
    }

    /// Nothing pinned, nothing recorded: an empty set. The one answer that must never appear here
    /// is the account id — passing it on is what put a teardown in every device's queue, and a
    /// caller cannot tell an account id from a device id by looking at the list.
    func testAPeerWeCannotNameTranslatesToNothing() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { _ in nil }

        XCTAssertTrue(SessionAddressing.deviceIds(ofPeer: accountA, in: context).isEmpty)
    }

    // MARK: - What must not be pinned

    /// `deviceId == SHA256(identityKey)[0..16]`, so the two halves of a row are one value. A pair
    /// that disagrees would make the derivation and the store two carriers of it, and the store
    /// would win everywhere the derivation is not re-run. Refused, not repaired.
    func testAPairThatDoesNotDeriveIsRefused() {
        let real = device(0x11)
        let mismatched = (deviceId: device(0x22).deviceId, identityKey: real.identityKey)

        SessionAddressing.recordDevices([mismatched], ofPeer: accountA, in: context)

        XCTAssertTrue(SessionAddressing.devices(ofPeer: accountA, in: context).isEmpty)
        XCTAssertNil(SessionAddressing.peer(ofDevice: mismatched.deviceId, in: context))
    }

    /// One bad pair in an answer must not cost the good ones: the loop refuses the row, not the
    /// fetch. Written because the first version returned early on a mismatch, which would have let
    /// a single malformed device entry keep an account's whole set unpinned.
    func testAGoodPairSurvivesABadOneInTheSameAnswer() {
        let good = device(0x33)
        let bad = (deviceId: device(0x22).deviceId, identityKey: device(0x11).identityKey)

        SessionAddressing.recordDevices([bad, good], ofPeer: accountA, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId), [good.deviceId])
    }

    /// An account id is not a device id, and must not become a row keyed by one.
    func testAnAccountIdIsNotRecordedAsADevice() {
        let bogus = (deviceId: accountA, identityKey: Data(repeating: 0x11, count: 32))

        SessionAddressing.recordDevices([bogus], ofPeer: accountA, in: context)

        XCTAssertTrue(SessionAddressing.devices(ofPeer: accountA, in: context).isEmpty)
    }

    /// Recording the same answer twice adds nothing. The uniqueness constraint is on `deviceId`,
    /// and a second row for one device would give `peer(ofDevice:)` two answers to choose between.
    func testRecordingTwiceIsIdempotent() {
        let one = device(0x11)
        SessionAddressing.recordDevices([one], ofPeer: accountA, in: context)
        SessionAddressing.recordDevices([one], ofPeer: accountA, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).count, 1)
    }

    /// A device already pinned to one account is not moved by a later answer claiming another.
    /// The server naming someone else's device as ours is exactly the claim `PeerDevice` is not
    /// allowed to strengthen; keeping the first pin means a rehome has to be deliberate.
    func testADeviceIsNotRehomedByALaterAnswer() {
        let one = device(0x11)
        SessionAddressing.recordDevices([one], ofPeer: accountA, in: context)
        SessionAddressing.recordDevices([one], ofPeer: accountB, in: context)

        XCTAssertEqual(SessionAddressing.devices(ofPeer: accountA, in: context).map(\.deviceId), [one.deviceId])
        XCTAssertTrue(SessionAddressing.devices(ofPeer: accountB, in: context).isEmpty)
        XCTAssertEqual(SessionAddressing.peer(ofDevice: one.deviceId, in: context)?.accountId, accountA)
    }
}

// MARK: - §A.3 — the server states the set, so absence becomes evidence

/// `recordDevices` could never prune, and said so: a device missing from one answer may be gone,
/// or the answer may be narrowed, or this client may have dropped it itself on a failed hybrid-PQ
/// check. Three states, one appearance.
///
/// `GetPreKeyBundlesResponse.active_devices` separates them by being the server's own answer about
/// which devices exist, independent of which bundles came back. `reconcileDevices` is the only
/// place allowed to delete a row.
///
/// Devices 2026-09-01: a Desktop signed out at 12:15:51 was deactivated server-side and stopped
/// being served within seconds; every peer went on holding its row, sealing fan-out copies to a key
/// nobody held. Peer A's set only lost it because A was reinstalled.
extension PeerDeviceSetTests {

    private var accountC: String { "14f28d31-0000-0000-0000-0000000000cc" }

    func testARetiredDeviceIsForgotten() throws {
        let kept = device(0x11)
        let retired = device(0x22)
        makeContact(id: accountC, key: kept.identityKey)
        SessionAddressing.recordDevices(
            [(deviceId: kept.deviceId, identityKey: kept.identityKey),
             (deviceId: retired.deviceId, identityKey: retired.identityKey)],
            ofPeer: accountC, in: context
        )
        XCTAssertEqual(
            Set(SessionAddressing.deviceIds(ofPeer: accountC, in: context)),
            [kept.deviceId, retired.deviceId],
            "pre-condition: both devices are pinned, or the deletion below proves nothing"
        )

        // The server now names only one of them.
        SessionAddressing.reconcileDevices(
            [(deviceId: kept.deviceId, identityKey: kept.identityKey)],
            activeSet: [kept.deviceId],
            ofPeer: accountC, in: context
        )

        XCTAssertEqual(
            SessionAddressing.deviceIds(ofPeer: accountC, in: context), [kept.deviceId],
            "a device the server no longer lists must be forgotten"
        )
    }

    /// **The rollout guard.** proto3 gives an absent field the same value as an empty one, so a
    /// server that predates `active_devices` answers exactly like an account whose every device was
    /// revoked. Not pruning costs one wasted copy; pruning on empty deletes every peer's device set
    /// on the first fetch after launch.
    func testAnEmptyActiveSetPrunesNothing() throws {
        let a = device(0x11)
        let b = device(0x22)
        makeContact(id: accountC, key: a.identityKey)
        SessionAddressing.recordDevices(
            [(deviceId: a.deviceId, identityKey: a.identityKey),
             (deviceId: b.deviceId, identityKey: b.identityKey)],
            ofPeer: accountC, in: context
        )

        SessionAddressing.reconcileDevices([], activeSet: [], ofPeer: accountC, in: context)

        XCTAssertEqual(
            Set(SessionAddressing.deviceIds(ofPeer: accountC, in: context)),
            [a.deviceId, b.deviceId],
            "an empty set is an old server, not an empty account"
        )
    }

    /// A device this client dropped locally — a failed hybrid-PQ bundle — is absent from `devices`
    /// but present in `activeSet`. It is alive; only that bundle was unusable. Pruning on the
    /// bundle list, which is what `recordDevices` was asked for and refused, would delete it.
    func testADeviceDroppedByLocalVerificationSurvives() throws {
        let good = device(0x11)
        let unverifiable = device(0x22)
        makeContact(id: accountC, key: good.identityKey)
        SessionAddressing.recordDevices(
            [(deviceId: good.deviceId, identityKey: good.identityKey),
             (deviceId: unverifiable.deviceId, identityKey: unverifiable.identityKey)],
            ofPeer: accountC, in: context
        )

        // The fetch returned both, but only one survived verification on this side.
        SessionAddressing.reconcileDevices(
            [(deviceId: good.deviceId, identityKey: good.identityKey)],
            activeSet: [good.deviceId, unverifiable.deviceId],
            ofPeer: accountC, in: context
        )

        XCTAssertEqual(
            Set(SessionAddressing.deviceIds(ofPeer: accountC, in: context)),
            [good.deviceId, unverifiable.deviceId],
            "the server says it is active; this client only failed to verify one of its bundles"
        )
    }

    /// The server contradicting itself inside one response: a bundle for a device its own set
    /// omits. The bundle is the half we can check — its key derives to the id — so it wins.
    func testABundleOutweighsItsOwnAbsenceFromTheSet() throws {
        let listed = device(0x11)
        let bundledButUnlisted = device(0x22)
        makeContact(id: accountC, key: listed.identityKey)
        SessionAddressing.recordDevices(
            [(deviceId: bundledButUnlisted.deviceId, identityKey: bundledButUnlisted.identityKey)],
            ofPeer: accountC, in: context
        )

        SessionAddressing.reconcileDevices(
            [(deviceId: listed.deviceId, identityKey: listed.identityKey),
             (deviceId: bundledButUnlisted.deviceId, identityKey: bundledButUnlisted.identityKey)],
            activeSet: [listed.deviceId],
            ofPeer: accountC, in: context
        )

        XCTAssertTrue(
            SessionAddressing.deviceIds(ofPeer: accountC, in: context)
                .contains(bundledButUnlisted.deviceId),
            "we hold a verified key for it; the list is the half without evidence"
        )
    }

    /// Retiring one account's device must not touch another's — the delete is scoped by the
    /// `accountId` predicate, and a scan that forgot it would empty the whole table.
    func testRetirementIsScopedToOneAccount() throws {
        let mine = device(0x11)
        let theirs = device(0x33)
        makeContact(id: accountC, key: mine.identityKey)
        makeContact(id: accountB, key: theirs.identityKey)
        SessionAddressing.recordDevices(
            [(deviceId: mine.deviceId, identityKey: mine.identityKey)], ofPeer: accountC, in: context
        )
        SessionAddressing.recordDevices(
            [(deviceId: theirs.deviceId, identityKey: theirs.identityKey)], ofPeer: accountB, in: context
        )

        // accountC has no active devices left, per the server.
        SessionAddressing.reconcileDevices(
            [], activeSet: ["ffffffffffffffffffffffffffffffff"], ofPeer: accountC, in: context
        )

        XCTAssertTrue(SessionAddressing.deviceIds(ofPeer: accountC, in: context).isEmpty)
        XCTAssertEqual(
            SessionAddressing.deviceIds(ofPeer: accountB, in: context), [theirs.deviceId],
            "another account's set is not this account's business"
        )
    }
}
