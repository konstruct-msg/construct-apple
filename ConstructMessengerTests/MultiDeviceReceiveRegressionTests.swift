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

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        super.tearDown()
    }

    @discardableResult
    private func pinnedUser(accountId: String) -> (user: User, key: Data, deviceId: String) {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let user = User(context: context)
        user.id = accountId
        user.knownIdentityKey = key
        try? context.save()
        return (user, key, deriveDeviceId(identityPublicKey: [UInt8](key)))
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
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: pinned.deviceId, in: context), pinned.key)
    }

    /// The one that actually broke: the sealed send resolves its recipient key whichever space the
    /// caller names the peer in.
    ///
    /// Mutation: remove the device-id branch from `recipientIdentityKey` — this reddens while the
    /// account-id case below still passes, which is exactly how the defect looked in production.
    func testTheSealedSendResolvesAPeerNamedByDeviceOrAccount() {
        let pinned = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        XCTAssertEqual(
            StealthSenderService.recipientIdentityKey(recipientId: pinned.user.id, context: context),
            pinned.key, "the account-space path is the one that always worked"
        )
        XCTAssertEqual(
            StealthSenderService.recipientIdentityKey(recipientId: pinned.deviceId, context: context),
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
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: a.deviceId, in: context), a.key)
        XCTAssertEqual(SessionAddressing.identityKey(ofDevice: b.deviceId, in: context), b.key)
    }

    /// An unknown device is not resolvable, and an account id is not a device id. Answering here
    /// would hand the sealed send a key belonging to somebody else.
    ///
    /// Mutation: drop the `isCryptoIdentity` guard — the account-id row would then be scanned
    /// against a value that is not a device id; this pins that it returns nothing.
    func testAnUnknownDeviceResolvesToNothing() {
        let pinned = pinnedUser(accountId: "289b95ca-8260-4b99-a79a-acaba5681b71")
        let stranger = deriveDeviceId(
            identityPublicKey: [UInt8](Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        )
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: stranger, in: context))
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: pinned.user.id, in: context))
        XCTAssertNil(SessionAddressing.identityKey(ofDevice: "", in: context))
    }

    // MARK: - The duplicate guard refusing the handler that armed it

    /// `routeIncomingMessage` marks a SENDER_SYNC processed **before** calling its handler, to
    /// close the redelivery window. The handler then asks `decryptMessage`, once per candidate
    /// session, which of our own devices sent it — and every candidate was refused on the strength
    /// of that claim.
    ///
    /// The result was not an error anyone saw: `messageNumber == 0` survived, because an unopened
    /// first message takes the init path, which does not consult the guard. Everything after it was
    /// dropped with "no own-device session opened", on every multi-device account, silently.
    ///
    /// This pins the shape of the fix rather than the crypto: the walk must ask about the session,
    /// and must not re-ask a message-level question its own caller already answered.
    ///
    /// Mutation: drop `claimedByThisHandler` at the call site in `openSenderSync` — this reddens.
    func testTheCandidateWalkDoesNotConsultItsOwnClaim() throws {
        let source = try XCTUnwrap(
            try? String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift"),
                encoding: .utf8
            )
        )
        let walk = try XCTUnwrap(source.range(of: "private func openSenderSync"))
        let body = String(source[walk.lowerBound...].prefix(1400))
        XCTAssertTrue(
            body.contains("claimedByThisHandler: true"),
            "openSenderSync decrypts one id once per candidate; without this it is refused by the "
            + "mark routeIncomingMessage made before calling it"
        )

        // And the claim itself is still made — removing it would reopen the redelivery window the
        // mark exists to close, which is a different regression with the same symptom.
        XCTAssertTrue(
            source.contains("if message.isSenderSync {\n            PersistentACKStore.shared.markProcessed("),
            "the pre-claim must stay: it is what dedups the server's second delivery"
        )
    }

    /// The guard still does its job for everyone else. It exists so a redelivered message does not
    /// decrypt against an advanced ratchet and archive a healthy session.
    ///
    /// Mutation: default `claimedByThisHandler` to true — this reddens.
    func testEveryOtherCallerStillGetsTheGuard() throws {
        let source = try XCTUnwrap(
            try? String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("ConstructMessenger/Security/CryptoManager.swift"),
                encoding: .utf8
            )
        )
        XCTAssertTrue(source.contains("claimedByThisHandler: Bool = false"),
                      "the bypass must be opt-in; defaulting it on removes the guard everywhere")
        XCTAssertTrue(source.contains("if !claimedByThisHandler, PersistentACKStore.shared.isProcessedInMemory"),
                      "the guard must still run for callers that did not claim the message")
    }
}
