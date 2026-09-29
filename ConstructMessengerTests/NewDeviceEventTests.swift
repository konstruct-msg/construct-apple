import XCTest
import CoreData
@testable import Construct_Messenger

/// The security event is a device the contact's account did not have — not a key different from
/// the one pinned per account, which a second device of the contact always was.
/// `decisions/a-new-device-is-the-security-event.md`. Canon: Android
/// `PeerDeviceRegistryNewDeviceTest`.
@MainActor
final class NewDeviceEventTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }
    private var raised: [String] = []

    private let me = "14f28d31-0000-0000-0000-00000000000a"
    private let peer = "14f28d31-0000-0000-0000-00000000000b"

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        UserDefaults.standard.removeObject(forKey: NewDeviceEvent.listedSetsKey)
        raised = []
        SessionAddressing.newDeviceSinkForTesting = { [weak self] in self?.raised.append($0) }
        SessionAddressing.ownAccountOverrideForTesting = me
    }

    override func tearDown() {
        SessionAddressing.newDeviceSinkForTesting = nil
        SessionAddressing.ownAccountOverrideForTesting = nil
        UserDefaults.standard.removeObject(forKey: NewDeviceEvent.listedSetsKey)
        KeyChangeUX.setActiveChatContact(nil)
        container = nil
        super.tearDown()
    }

    private func device(_ byte: UInt8) -> (deviceId: String, identityKey: Data) {
        let key = Data(repeating: byte, count: 32)
        return (deviceId: deriveDeviceId(identityPublicKey: [UInt8](key)), identityKey: key)
    }

    @discardableResult
    private func makeContact(_ id: String) -> User {
        let user = User(context: context)
        user.id = id
        user.username = ""
        user.displayName = "Bob"
        user.isContact = true
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.addedAt = Date()
        try! context.save()
        return user
    }

    // MARK: - The rule

    func testTheRule() {
        XCTAssertEqual(NewDeviceEvent.events(incoming: ["c"], listed: ["a"], pinned: ["b"]), ["c"])
        XCTAssertEqual(NewDeviceEvent.events(incoming: ["c"], listed: nil, pinned: []), [],
                       "before the account's set was listed, every device is first sight")
        XCTAssertEqual(NewDeviceEvent.events(incoming: ["a", "b"], listed: ["a"], pinned: ["b"]), [])
    }

    // MARK: - Wired into the device set

    /// First contact: the invite pins one device, then the first listing names the rest. Neither
    /// is an event. Mutation: raise on any device not pinned before — this reddens.
    func testTheInviteDeviceAndTheFirstListAreFirstSight() {
        let one = device(0x11), two = device(0x22)
        SessionAddressing.recordDevices([one], ofPeer: peer, in: context)
        SessionAddressing.reconcileDevices([one, two], activeSet: [one.deviceId, two.deviceId], ofPeer: peer, in: context)

        XCTAssertEqual(raised, [])
    }

    /// Mutation: never record the listed set — the ghost device goes unnoticed.
    func testADeviceTheListedSetDidNotNameIsRaised() {
        let one = device(0x11), ghost = device(0x33)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId], ofPeer: peer, in: context)
        SessionAddressing.reconcileDevices(
            [one, ghost], activeSet: [one.deviceId, ghost.deviceId], ofPeer: peer, in: context
        )

        XCTAssertEqual(raised, [peer])
    }

    /// A sender certificate or an invite after the listing is a way in too.
    func testADeviceFirstHeardOutsideAListingIsRaised() {
        let one = device(0x11), ghost = device(0x44)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId], ofPeer: peer, in: context)

        XCTAssertEqual(SessionAddressing.recordDevices([ghost], ofPeer: peer, in: context), [ghost.deviceId])
        XCTAssertEqual(raised, [peer])
    }

    /// A device the list names but whose bundle did not come back is as new as one that did.
    /// Mutation: evaluate only the bundles — this reddens.
    func testAListedDeviceWithoutABundleIsRaised() {
        let one = device(0x11), unbundled = device(0x55)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId], ofPeer: peer, in: context)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId, unbundled.deviceId], ofPeer: peer, in: context)

        XCTAssertEqual(raised, [peer])
    }

    /// The same device again — from the list, then its certificate — is not raised twice.
    func testAKnownDeviceIsNotRaisedAgain() {
        let one = device(0x11), two = device(0x22)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId], ofPeer: peer, in: context)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId, two.deviceId], ofPeer: peer, in: context)
        SessionAddressing.recordDevices([two], ofPeer: peer, in: context)

        XCTAssertEqual(raised, [peer], "listed once, raised once")
    }

    // MARK: - The invite no longer compares one key per account

    /// An invite from the contact's other device carries a different key. That used to be
    /// `.keyChanged`; it is a device, and before a listing it is first sight.
    func testASecondInviteKeyIsNotAKeyChange() {
        let user = makeContact(peer)
        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: device(0x11).identityKey)
        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: device(0x22).identityKey)

        XCTAssertNotEqual(user.ktStatus, .keyChanged)
        XCTAssertEqual(Set(SessionAddressing.deviceIds(ofPeer: peer, in: context)),
                       [device(0x11).deviceId, device(0x22).deviceId])
        XCTAssertEqual(raised, [])
    }

    // MARK: - Raising and acknowledging

    /// Mutation: drop the `securityNotice` write — the banner has nothing to read.
    func testRaiseKeepsTheNoticeUntilAcknowledged() {
        makeContact(peer)
        XCTAssertTrue(KeyChangeUX.raise(.newDevice, userId: peer, context: context))
        let user = try! context.fetch(User.fetchRequest()).first { $0.id == peer }!
        XCTAssertEqual(user.trustAlert, .newDevice)

        user.ktStatus = .verified   // a later fetch's verdict does not clear it
        XCTAssertEqual(user.trustAlert, .newDevice)

        XCTAssertTrue(KeyChangeUX.acknowledgeKeyChange(userId: peer, context: context))
        XCTAssertNil(user.trustAlert)
    }

    func testOurOwnAccountIsNeverTheSubject() {
        makeContact(me)
        XCTAssertFalse(KeyChangeUX.raise(.newDevice, userId: me, context: context))
    }

    func testAFailedProofIsAnAlertAndAcknowledgingAcceptsIt() {
        let user = makeContact(peer)
        user.ktStatus = .failed
        XCTAssertEqual(user.trustAlert, .verificationFailed)
        XCTAssertTrue(KeyChangeUX.acknowledgeKeyChange(userId: peer, context: context))
        XCTAssertEqual(user.ktStatus, .verified)
    }

    /// The legacy value is not an alert: nearly every stored one was a second device.
    func testTheLegacyKeyChangedStatusRaisesNothing() {
        let user = makeContact(peer)
        user.ktStatus = .keyChanged
        XCTAssertNil(user.trustAlert)
    }

    func testSafetyNumbersCoverEveryDevice() {
        let user = makeContact(peer)
        SessionAddressing.recordDevices([device(0x11), device(0x22)], ofPeer: peer, in: context)
        XCTAssertEqual(Set(KeyChangeUX.safetyDeviceIds(for: user, context: context)),
                       [device(0x11).deviceId, device(0x22).deviceId])
    }
}
