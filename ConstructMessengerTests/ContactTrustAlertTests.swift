import XCTest
import CoreData
@testable import Construct_Messenger

/// The alerts a contact can carry, and the one it no longer does: a device the account did not
/// have, which could not tell a device the contact linked from one the server added.
/// `decisions/new-device-alarm-waits-for-cross-signing.md`.
@MainActor
final class ContactTrustAlertTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    private let me = "14f28d31-0000-0000-0000-00000000000a"
    private let peer = "14f28d31-0000-0000-0000-00000000000b"

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        SessionAddressing.ownAccountOverrideForTesting = me
    }

    override func tearDown() {
        SessionAddressing.ownAccountOverrideForTesting = nil
        KeyChangeUX.setActiveChatContact(nil)
        container = nil
        super.tearDown()
    }

    private func device(_ byte: UInt8) -> (deviceId: String, identityKey: Data) {
        let key = Data(repeating: byte, count: 32)
        return (deviceId: deriveDeviceId(identityPublicKey: key), identityKey: key)
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

    // MARK: - A new device is pinned, not announced

    /// A device the listed set did not name joins the set and raises nothing.
    func testANewDeviceAfterTheListingIsPinnedWithoutAnAlert() {
        let user = makeContact(peer)
        let one = device(0x11), added = device(0x33)
        SessionAddressing.reconcileDevices([one], activeSet: [one.deviceId], ofPeer: peer, in: context)
        SessionAddressing.reconcileDevices(
            [one, added], activeSet: [one.deviceId, added.deviceId], ofPeer: peer, in: context
        )

        XCTAssertEqual(Set(SessionAddressing.deviceIds(ofPeer: peer, in: context)), [one.deviceId, added.deviceId])
        XCTAssertNil(user.trustAlert)
    }

    /// Rows stored while the alarm existed carry 2. Mutation: give 2 a case again — this reddens.
    func testAStoredNewDeviceNoticeReadsAsNone() {
        let user = makeContact(peer)
        user.securityNoticeRaw = 2
        XCTAssertEqual(user.securityNotice, .none)
        XCTAssertNil(user.trustAlert)
    }

    // MARK: - The invite no longer compares one key per account

    /// An invite from the contact's other device carries a different key. That used to be
    /// `.keyChanged`; it is a device of the account.
    func testASecondInviteKeyIsNotAKeyChange() {
        let user = makeContact(peer)
        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: device(0x11).identityKey)
        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: device(0x22).identityKey)

        XCTAssertNotEqual(user.ktStatus, .keyChanged)
        XCTAssertEqual(Set(SessionAddressing.deviceIds(ofPeer: peer, in: context)),
                       [device(0x11).deviceId, device(0x22).deviceId])
        XCTAssertNil(user.trustAlert)
    }

    // MARK: - Raising and acknowledging

    /// Mutation: drop the `securityNotice` write — the banner has nothing to read.
    func testRaiseKeepsTheNoticeUntilAcknowledged() {
        makeContact(peer)
        XCTAssertTrue(KeyChangeUX.raise(.addressChanged, userId: peer, context: context))
        let user = try! context.fetch(User.fetchRequest()).first { $0.id == peer }!
        XCTAssertEqual(user.trustAlert, .addressChanged)

        user.ktStatus = .verified   // a later fetch's verdict does not clear it
        XCTAssertEqual(user.trustAlert, .addressChanged)

        XCTAssertTrue(KeyChangeUX.acknowledgeKeyChange(userId: peer, context: context))
        XCTAssertNil(user.trustAlert)
    }

    func testOurOwnAccountIsNeverTheSubject() {
        makeContact(me)
        XCTAssertFalse(KeyChangeUX.raise(.addressChanged, userId: me, context: context))
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
