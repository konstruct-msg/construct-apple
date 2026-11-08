//
//  MultiDeviceReceiveRegressionTests.swift
//  ConstructMessengerTests
//
//  Two defects the three-device stand found on 2026-08-27, both invisible to every unit test that
//  existed because both need a *second device in one account* to occur at all.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CoreData
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class MultiDeviceReceiveRegressionTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        try await super.setUp()
        let container = PersistenceController(inMemory: true).container
        context = container.viewContext
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: container))
        LocalRepositories.useContactsForTesting(container)
    }

    override func tearDown() async throws {
        LocalRepositories.usePeerDevicesForTesting(nil)
        LocalRepositories.useContactsForTesting(nil)
        context = nil
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        try await super.tearDown()
    }

    @discardableResult
    private func pinnedUser(accountId: String) -> (user: User, key: Data, deviceId: String) {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let user = User(context: context)
        user.id = accountId
        user.knownIdentityKey = key
        user.username = ""
        user.displayName = ""
        try! context.save()
        return (user, key, deriveDeviceId(identityPublicKey: key))
    }

    // MARK: - A device id reaching an account-space lookup

    /// The seam read backwards. Paths that start from a core action are handed a `contactId` — a
    /// device id — and `User.id` is an account id, so the row lookup finds nothing.
    ///
    /// Devices 2026-08-27: the peer's Double Ratchet diverged once per incoming message and it
    /// could not send END_SESSION to say so — `IK_MISS[no_row]` for `b26a2cf8…`, every time,
    /// because that is a device id. Nothing retried and nothing surfaced.
    ///
    /// Mutation: delete the reverse resolution in `identityKey(ofDevice:in:)` (return nil) — this
    /// reddens, and so does the sealed-send test below.
    func testAPinnedKeyIsReachableFromItsDeviceId() {
        let pinned = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: pinned.deviceId), pinned.key)
    }

    /// The one that actually broke: the sealed send resolves its recipient key whichever space the
    /// caller names the peer in.
    ///
    /// Mutation: remove the device-id branch from `recipientIdentityKey` — this reddens while the
    /// account-id case below still passes, which is exactly how the defect looked in production.
    func testTheSealedSendResolvesAPeerNamedByDeviceOrAccount() {
        let pinned = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        XCTAssertEqual(
            StealthSenderService.recipientIdentityKey(recipientId: pinned.user.id),
            pinned.key, "the account-space path is the one that always worked"
        )
        XCTAssertEqual(
            StealthSenderService.recipientIdentityKey(recipientId: pinned.deviceId),
            pinned.key, "a device id must reach the same pin, or every sealed send to it fails closed"
        )
    }

    /// The resolution is exact, not "any pinned key": two contacts must not answer for each other.
    ///
    /// Mutation: return the first pinned key without comparing the derived id — this reddens.
    func testTheReverseResolutionNamesOneContact() {
        let a = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        let b = pinnedUser(accountId: "8c1f0b2e-0000-4000-8000-000000000001")
        XCTAssertNotEqual(a.deviceId, b.deviceId)
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: a.deviceId), a.key)
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: b.deviceId), b.key)
    }

    /// An unknown device is not resolvable, and an account id is not a device id. Answering here
    /// would hand the sealed send a key belonging to somebody else.
    ///
    /// Mutation: drop the `isCryptoIdentity` guard — the account-id row would then be scanned
    /// against a value that is not a device id; this pins that it returns nothing.
    func testAnUnknownDeviceResolvesToNothing() {
        let pinned = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        let stranger = deriveDeviceId(
            identityPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        )
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: stranger))
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: pinned.user.id))
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: ""))
    }

    // MARK: - A SENDER_SYNC is deduplicated by the router, not inside the decrypt

    /// `routeIncomingMessage` claims a SENDER_SYNC as processed **before** calling its handler, to
    /// close the redelivery window. On 2026-08-27 a guard inside `decryptMessage` then refused the
    /// handler on the strength of that claim and every copy after the first was lost. The guard is
    /// gone (todo/252); the claim stays, and the router is where a redelivered copy stops.
    ///
    /// Mutation: drop the guard on `isDeduplicatedHere` in the router — the second assertion
    /// reddens; reintroduce a processed check in `decryptMessage` — the third reddens.
    func testACopyIsClaimedByTheRouterAndNotRefusedByTheDecrypt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let router = try String(contentsOf: root.appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift"), encoding: .utf8)
        let crypto = try String(contentsOf: root.appendingPathComponent("ConstructMessenger/Security/CryptoManager+MessageCrypto.swift"), encoding: .utf8)
        XCTAssertTrue(
            router.contains("if message.isSenderSync {\n            PersistentACKStore.shared.markProcessed("),
            "the pre-claim must stay: it is what dedups the server's second delivery"
        )
        XCTAssertTrue(router.contains("if Self.isDeduplicatedHere(message), PersistentACKStore.shared.isProcessed(message.id) {"))
        XCTAssertFalse(crypto.contains("PersistentACKStore.shared.isProcessed"), "the decrypt asks no duplicate question")
    }

    /// Exactly the two carriers the core's router does not read are deduplicated here; an
    /// ordinary message is not, whether it opens a session or follows one. Real wire payloads, so
    /// the second carries message number 1.
    /// Mutation: add ordinary messages to the set by any property — this reddens.
    func testOnlyTheCarriersTheCoreDoesNotRouteAreDeduplicatedHere() throws {
        let (writer, _) = try makeTestDevice()
        let (reader, readerId) = try makeTestDevice()
        _ = try writer.initSession(contactId: readerId, recipientBundle: try reader.pqxdhTestBundle())
        let first = try writer.encryptToWire(contactId: readerId, plaintext: Data("0".utf8))
        let second = try writer.encryptToWire(contactId: readerId, plaintext: Data("1".utf8))
        func message(_ type: Shared_Proto_Core_V1_ContentType, _ wire: Data = Data()) -> ChatMessage {
            ChatMessage(id: "m", from: "a", to: "b", timestamp: 0, contentType: type.byte, rawPayload: wire)
        }
        XCTAssertEqual(message(.e2EeSignal, second).messageNumber, 1, "premise: a message past the first")

        XCTAssertTrue(MessageRouter.isDeduplicatedHere(message(.senderSync)))
        XCTAssertTrue(MessageRouter.isDeduplicatedHere(message(.decryptionError)))
        XCTAssertFalse(MessageRouter.isDeduplicatedHere(message(.e2EeSignal, first)))
        XCTAssertFalse(MessageRouter.isDeduplicatedHere(message(.e2EeSignal, second)))
    }

}
