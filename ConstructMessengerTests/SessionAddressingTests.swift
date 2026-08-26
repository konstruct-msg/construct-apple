//
//  SessionAddressingTests.swift
//  ConstructMessengerTests
//
//  The seam between the account space and the crypto space. Acceptance is mutation-based;
//  each test names the mutation that must redden it.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class SessionAddressingTests: XCTestCase {

    private let userId = "289b95ca-8260-4b99-a79a-acaba5681b71"
    private var identityKey = Data()
    private var expectedDeviceId = ""

    override func setUp() {
        super.setUp()
        identityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        expectedDeviceId = deriveDeviceId(identityPublicKey: [UInt8](identityKey))
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { [identityKey, userId] asked in
            asked == userId ? identityKey : nil
        }
    }

    override func tearDown() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - What a crypto identity is

    /// A device id is a hash of the identity key, so the app must never invent one. This pins the
    /// shape the seam recognises against the core's own derivation.
    func testADeviceIdIsThirtyTwoHexCharacters() {
        XCTAssertEqual(expectedDeviceId.count, 32)
        XCTAssertTrue(SessionAddressing.isCryptoIdentity(expectedDeviceId))
    }

    /// The two spaces must not be confusable, which is the entire premise of the seam.
    ///
    /// Mutation: accept any 32-or-more-character string — the UUID below is 36 and this reddens.
    func testAnAccountIdIsNotACryptoIdentity() {
        XCTAssertFalse(SessionAddressing.isCryptoIdentity(userId))
        XCTAssertFalse(SessionAddressing.isCryptoIdentity(""))
        XCTAssertFalse(SessionAddressing.isCryptoIdentity("\(userId):\(expectedDeviceId)"))
        // 32 characters, but not hex.
        XCTAssertFalse(SessionAddressing.isCryptoIdentity(String(repeating: "z", count: 32)))
    }

    // MARK: - Translation

    /// The whole point: what reaches the ratchet names a device.
    ///
    /// Mutation: return the input unchanged — this reddens.
    func testAUserIdResolvesToThePinnedDevice() {
        XCTAssertEqual(SessionAddressing.contactId(forPeer: userId), expectedDeviceId)
    }

    /// The per-device paths already hold a device id when they reach the seam, and it must come
    /// out the same.
    ///
    /// This pins the value, not the branch: dropping the pass-through in `contactId(forPeer:)`
    /// reddens nothing, because a device id has no `User` row and the resolution below returns it
    /// unchanged anyway. That branch is a fetch the receive path does not take, and it is
    /// documented as such rather than given a test that cannot fail.
    func testADeviceIdPassesThroughUnchanged() {
        XCTAssertEqual(SessionAddressing.contactId(forPeer: expectedDeviceId), expectedDeviceId)
    }

    /// No pinned key means we have never verified this contact — the same state in which no
    /// session exists. The seam answers `nil`, and the caller treats that as "no session".
    ///
    /// It used to hand back the input instead, on the reasoning that the next call would fail as
    /// "no session" anyway. That made one function answer two questions with one type, and it cost
    /// the guard: with an account id able to leave the seam legitimately, nothing could assert
    /// that what reaches the core is a device id.
    ///
    /// Mutation: return the input for an unknown peer — this reddens.
    func testAnUnpinnedPeerIsNamedByNothingAtAll() {
        let stranger = "8c1f0b2e-0000-4000-8000-000000000001"
        XCTAssertNil(SessionAddressing.contactId(forPeer: stranger))
        XCTAssertNil(SessionAddressing.cryptoIdentity(ofUser: stranger))
    }

    /// Translation is idempotent, which is what lets the seam sit at several layers at once —
    /// `restoreSession` translates, and so does the `encryptMessage` that called it.
    func testTranslatingTwiceIsTranslatingOnce() {
        let once = try? XCTUnwrap(SessionAddressing.contactId(forPeer: userId))
        let unwrapped = try? XCTUnwrap(once)
        XCTAssertEqual(SessionAddressing.contactId(forPeer: unwrapped ?? ""), unwrapped)
    }

    /// Whatever the seam produces is a crypto identity — never a composite, never an account id.
    /// The composite form is what broke the AD: the sender addressed `<userId>:<deviceId>` while
    /// the receiver's own identity stayed a bare UUID.
    ///
    /// Mutation: have the seam join the two ids, or return its input — this reddens.
    func testEverythingTheSeamProducesIsACryptoIdentity() {
        for input in [userId, expectedDeviceId] {
            guard let out = SessionAddressing.contactId(forPeer: input) else {
                XCTFail("\(input) should resolve")
                continue
            }
            XCTAssertTrue(SessionAddressing.isCryptoIdentity(out), "not a device id: \(out)")
            XCTAssertFalse(out.contains(":"), "a contact id must name one device: \(out)")
        }
    }

    /// A composite id cannot be resolved and must not be mistaken for an identity. It is handed
    /// on unchanged, where `verify_identity` in the core rejects it by name — loudly, at the
    /// moment it is applied, rather than as a permanent AEAD failure later.
    ///
    /// Mutation: accept a composite as a crypto identity — this reddens.
    func testALegacyCompositeIdIsNotAnIdentity() {
        let composite = "\(userId):\(expectedDeviceId)"
        XCTAssertFalse(SessionAddressing.isCryptoIdentity(composite))
        XCTAssertNil(SessionAddressing.cryptoIdentity(ofUser: composite))
    }

    /// An empty peer id cannot name anybody, and an empty contact id is a session every contact
    /// would share.
    func testAnEmptyPeerResolvesToNothing() {
        XCTAssertNil(SessionAddressing.cryptoIdentity(ofUser: ""))
    }

    /// The identity key in hand outranks the contact list, and is the only source that answers at
    /// first contact — which is when X3DH runs.
    ///
    /// Mutation: have the init paths resolve through the pinned row instead — the responder then
    /// binds an account id into an AD whose initiator bound a device id, and
    /// `initReceivingSession` fails with "AEAD decryption failed" on a valid bundle. Seen on the
    /// three-simulator stand 2026-08-26.
    func testAKeyInHandNamesTheDeviceWithoutAPinnedRow() {
        let stranger = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let expected = deriveDeviceId(identityPublicKey: [UInt8](stranger))
        XCTAssertEqual(SessionAddressing.cryptoIdentity(ofIdentityKey: stranger), expected)
        XCTAssertTrue(SessionAddressing.isCryptoIdentity(expected))
        // The same key resolves the same way whether or not the contact list knows the peer.
        XCTAssertEqual(SessionAddressing.cryptoIdentity(ofIdentityKey: identityKey), expectedDeviceId)
    }

    /// An absent key names nobody rather than a shared empty identity.
    func testNoKeyNamesNoDevice() {
        XCTAssertNil(SessionAddressing.cryptoIdentity(ofIdentityKey: Data()))
    }

    // MARK: - Our own side of the mirror

    /// The AD is mirrored, so our local identity must live in the same space as the contact id the
    /// peer writes for us. It used to be the account UUID, which is what made a second device
    /// unaddressable: the sender named `<userId>:<deviceId>` and this stayed a bare UUID.
    ///
    /// Empty is allowed and is a state `setLocalUserId` refuses to hand the core; an account id is
    /// not allowed at all.
    ///
    /// Mutation: return the signed-in account id — this reddens.
    func testOurLocalIdentityIsNeverAnAccountId() {
        let local = SessionAddressing.localIdentity()
        if local.isEmpty { return }  // no account on this simulator run
        XCTAssertTrue(
            SessionAddressing.isCryptoIdentity(local),
            "the core would bind \(local) into every AD it writes"
        )
    }
}
