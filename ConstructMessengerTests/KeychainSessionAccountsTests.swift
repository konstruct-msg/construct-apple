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
}
