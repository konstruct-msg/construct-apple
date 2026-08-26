//
//  KeychainSessionAccountsTests.swift
//  ConstructMessengerTests
//
//  2026-08-08: `deleteAllSessions()` had been a no-op since it was written. It enumerated with
//  `kSecAttrService == Bundle.main.bundleIdentifier`, while `KeychainManager.save` writes no
//  service attribute at all — so account deletion and device link left every `session_<uuid>`
//  ratchet blob on the device, and the only log line that would have said so
//  ("Deleted N session(s)") was guarded by `N > 0`.
//
//  The fix could not be `hasPrefix("session_")`: the auth token is `session_token`, and
//  `deleteAllE2EESessions()` runs from `prepareForDeviceLink()` while the user is signed in.
//  These tests pin both halves — what must be deleted, and what must survive.
//

import XCTest
@testable import Construct_Messenger

final class KeychainSessionAccountsTests: XCTestCase {

    private let contactId = "14f28d31-9f4a-4c1e-8b77-0d2a6e5f3c91"   // ServerUserId shape
    private let deviceId = "6f5e37ac1b9d40e2a8c37f5b12de904a"        // CryptoDeviceId shape

    // MARK: - What the wipe must reach

    func testLiveRatchetBlobIsSessionState() {
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_\(contactId)"))
    }

    func testArchivedSessionsAreSessionState() {
        // `SessionArchiveManager` writes "session_archives_<userId>"; a fresh identity must not
        // inherit the previous one's archives.
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_archives_\(contactId)"))
    }

    func testUppercaseUuidIsStillSessionState() {
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_\(contactId.uppercased())"))
    }

    func testDeviceIdShapedBlobIsSessionState() {
        // Not supposed to exist — session addressing is ServerUserId (see UserIdentity.swift) —
        // but the historical ID-space mix-up could have written one, and leaving a ratchet blob
        // behind on account deletion is the worse outcome.
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_\(deviceId)"))
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_archives_\(deviceId)"))
    }

    // MARK: - What must NOT be deleted

    func testAuthTokenIsNotSessionState() {
        // The whole reason this is a decision and not a prefix check: deleting this during
        // prepareForDeviceLink() signs the user out mid-link.
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_token"))
    }

    func testBareNamespaceIsNotSessionState() {
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_"))
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_archives_"))
    }

    func testAFutureNeighbourInTheNamespaceIsLeftAlone() {
        // Nobody adding "session_<something>" will read KeychainSessionAccounts first. An
        // unrecognised suffix must survive rather than be wiped on the next device link.
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_epoch"))
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_token_v2"))
    }

    func testOtherCryptoAccountsAreNotSessionState() {
        for account in ["identity_key", "signed_prekey", "crypto_otpks",
                        "construct.kyber_session_state", "deviceSigningKey"] {
            XCTAssertFalse(KeychainSessionAccounts.isSessionState(account), account)
        }
    }

    func testPrefixMustBeAtTheStart() {
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("old_session_\(contactId)"))
    }

    // MARK: - Malformed identities

    func testNearMissIdentitiesAreNotSessionState() {
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_\(contactId.dropLast())"),
                       "a truncated UUID is not an identity")
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_\(deviceId.dropLast())"),
                       "31 hex chars is not a CryptoDeviceId")
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_" + String(repeating: "z", count: 32)),
                       "32 non-hex chars is not a CryptoDeviceId")
    }

    // MARK: - The per-device shape (2026-08-26)

    private let perDeviceUser = "2096553c-1c91-47fb-ba5f-3586d14d358e"
    private let perDeviceDevice = "44f843866b3bfa57055e4037b25a3ce6"

    /// The shape that survived every wipe until 2026-08-26.
    ///
    /// `MultiDeviceSendCoordinator.sessionKey` has produced `<uuid>:<hex>` since multi-device
    /// shipped, and this predicate accepted neither a colon nor either half in that position — so
    /// `deleteAllE2EESessions()` left per-device ratchet state behind at exactly the two moments
    /// it exists for, `prepareForDeviceLink()` and `resetOrchestratorStateForDeviceLink()`. The
    /// file's own comment ruled the case out ("No such id should exist"), which is why nobody
    /// looked. Same defect as 2026-08-08, one shape further along.
    ///
    /// Mutation: drop the colon branch from `isIdentityShaped` — this reddens.
    func testPerDeviceSessionIsSessionState() {
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_\(perDeviceUser):\(perDeviceDevice)"))
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_archives_\(perDeviceUser):\(perDeviceDevice)"))
    }

    /// Both halves are checked, so a colon alone does not make an account deletable. A looser
    /// match would start deleting whichever tenant of this namespace is added next.
    func testMalformedPairIsNotSessionState() {
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_\(perDeviceUser):"))
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_:\(perDeviceDevice)"))
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_token:\(perDeviceDevice)"))
        XCTAssertFalse(KeychainSessionAccounts.isSessionState("session_\(perDeviceUser):not-a-device"))
    }

    /// The account name and the contact id it carries round-trip through one definition. Both
    /// incidents this file records came from a second spelling of the same shape.
    func testAccountAndContactIdRoundTrip() {
        for contactId in [perDeviceUser, perDeviceDevice, "\(perDeviceUser):\(perDeviceDevice)"] {
            let account = KeychainSessionAccounts.account(for: contactId)
            XCTAssertEqual(KeychainSessionAccounts.contactId(ofAccount: account), contactId)
        }
    }

    /// The session store is its own device index: a per-device account names both halves, so the
    /// set of a peer's devices we hold sessions with needs no second list kept in agreement.
    func testPerDeviceContactIsReadBack() {
        let parsed = KeychainSessionAccounts.perDeviceContact(
            ofAccount: "session_\(perDeviceUser):\(perDeviceDevice)")
        XCTAssertEqual(parsed?.userId, perDeviceUser)
        XCTAssertEqual(parsed?.deviceId, perDeviceDevice)
    }

    /// A plain session names no device, and must not be read as if it did.
    func testPlainSessionHasNoDeviceHalf() {
        XCTAssertNil(KeychainSessionAccounts.perDeviceContact(ofAccount: "session_\(perDeviceUser)"))
        XCTAssertNil(KeychainSessionAccounts.perDeviceContact(ofAccount: "session_token"))
    }

    // MARK: - Where the core's durable slots land
    //
    // The core names *what* the bytes are (`SecureStoreSlot`); this file decides *where* they go.
    // Until 2026-08-26 the core sent a formatted key and iOS parsed it apart and rebuilt it —
    // six copies of one naming rule, one of which (`CallManager`) silently did nothing for every
    // slot that was not a session.

    /// Every slot the core can emit lands somewhere distinct. A collision would have two kinds of
    /// state overwriting each other under one account, which no test downstream would notice
    /// because each writer would read back exactly what it wrote.
    ///
    /// Mutation: give any two slots the same account — this reddens.
    func testEverySlotLandsInItsOwnAccount() {
        let slots: [CfeSecureStoreSlot] = [
            .session(contactId: contactId),
            .sessionArchive(contactId: contactId),
            .pqDeferred(contactId: contactId),
            .kyberSessionState,
            .kyberSignedPrekey(keyId: 7),
            .orchestratorState
        ]
        let accounts = slots.map(KeychainSessionAccounts.account(for:))
        XCTAssertEqual(Set(accounts).count, slots.count, "slots collide: \(accounts)")
        XCTAssertFalse(accounts.contains(""), "a slot with no account would silently drop its bytes")
    }

    /// The two session-shaped slots must be reachable by the wipe. This is the join the 2026-08-26
    /// incident was missing: the namespace was defined in one place and swept by another.
    ///
    /// Mutation: name the archive account anything outside the `session_` namespace — this reddens.
    func testSessionSlotsAreRecognisedByTheWipe() {
        for slot in [CfeSecureStoreSlot.session(contactId: contactId),
                     .sessionArchive(contactId: contactId),
                     .session(contactId: "\(perDeviceUser):\(perDeviceDevice)")] {
            let account = KeychainSessionAccounts.account(for: slot)
            XCTAssertTrue(
                KeychainSessionAccounts.isSessionState(account),
                "\(account) holds ratchet state but the wipe would leave it behind"
            )
        }
    }

    /// The slots that are not session state must NOT be swept by the session wipe — it runs while
    /// the user is still signed in (`prepareForDeviceLink`), and it is not the account teardown.
    ///
    /// Mutation: move any of them into the `session_` namespace — this reddens.
    func testNonSessionSlotsAreNotSweptBySessionWipe() {
        for slot in [CfeSecureStoreSlot.pqDeferred(contactId: contactId),
                     .kyberSessionState,
                     .kyberSignedPrekey(keyId: 7),
                     .orchestratorState] {
            let account = KeychainSessionAccounts.account(for: slot)
            XCTAssertFalse(
                KeychainSessionAccounts.isSessionState(account),
                "\(account) is not a ratchet blob and must survive a session wipe"
            )
        }
    }

    /// `SessionArchiveManager` builds its Keychain key from the same function, so the archive a
    /// `SessionTerminated` action produces and the archive the manager reads are one account.
    func testTheArchiveAccountIsTheOneTheManagerUses() {
        XCTAssertEqual(
            KeychainSessionAccounts.account(for: .sessionArchive(contactId: contactId)),
            "session_archives_\(contactId)"
        )
    }
}
