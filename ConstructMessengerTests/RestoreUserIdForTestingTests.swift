import XCTest
@testable import Construct_Messenger

/// A test that signs in as a test account puts back what it found — an account, or none.
///
/// Until 2026-11-20 five tests restored only an account that was there: on a simulator nobody had
/// signed in on, their own id stayed in the Keychain, and `DeviceCertificateLinkTests` (11 tests)
/// then took its test peer for this account and judged nothing. Mutations: keep the Keychain id
/// on «none» (the Keychain assertion reddens); keep the in-memory one (`currentUserId` reddens).
@MainActor
final class RestoreUserIdForTestingTests: XCTestCase {

    func testNoAccountFoundIsNoAccountLeft() {
        let found = AuthSessionManager.shared.currentUserId
        defer { AuthSessionManager.shared.restoreUserIdForTesting(found) }

        AuthSessionManager.shared.updateUserId("e7a4e3d2-0000-4000-8000-0000000000ff")
        AuthSessionManager.shared.restoreUserIdForTesting(nil)

        XCTAssertNil(AuthSessionManager.shared.currentUserId)
        XCTAssertNil(KeychainManager.shared.loadUserID())
    }

    func testAnAccountFoundIsTheAccountLeft() {
        let found = AuthSessionManager.shared.currentUserId
        defer { AuthSessionManager.shared.restoreUserIdForTesting(found) }

        AuthSessionManager.shared.updateUserId("e7a4e3d2-0000-4000-8000-0000000000ff")
        AuthSessionManager.shared.restoreUserIdForTesting("e7a4e3d2-0000-4000-8000-0000000000ee")

        XCTAssertEqual(AuthSessionManager.shared.currentUserId, "e7a4e3d2-0000-4000-8000-0000000000ee")
    }
}
