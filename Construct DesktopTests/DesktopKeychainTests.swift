//
//  DesktopKeychainTests.swift
//  Construct DesktopTests
//
//  Does the Keychain work on macOS, and does it work the *same way*?
//
//  Two questions, and the second is the one that matters for what this target is for. The desktop
//  app exists as a second real device in one account so multi-device can be tested at all, and a
//  device whose Keychain quietly behaves differently is a test instrument that lies.
//
//  Driven through the named accessors the app actually uses — `saveSessionData` and friends — not
//  through the private `save(_:forKey:accessible:)`. Widening that to `internal` for a test would
//  undo the design of the file, and testing the accessors is the better test anyway: it covers the
//  path production takes, including the account-name construction.
//

import XCTest
import Security
@testable import Construct_Desktop

final class DesktopKeychainTests: XCTestCase {

    /// A crypto identity shape, since `KeychainSessionAccounts` builds the account name from it.
    private let contact = "ffffffffffffffffffffffffffffff01"

    override func tearDown() {
        KeychainManager.shared.deleteSession(for: contact)
        super.tearDown()
    }

    /// The plain requirement: what goes in comes out, on this platform, in this sandbox.
    ///
    /// Less obvious than it reads. The app writes generic passwords with **no** `kSecAttrService`
    /// — identity is the account alone — which is unusual enough that a platform difference in how
    /// an empty service is matched would break every read while every write reported success.
    func testASessionSurvivesARoundTrip() {
        let payload = Data((0..<128).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        XCTAssertTrue(
            KeychainManager.shared.saveSessionData(payload, for: contact),
            "the macOS Keychain refused a write the app makes on every ratchet step"
        )
        XCTAssertEqual(KeychainManager.shared.loadSessionData(for: contact), payload)
    }

    /// Overwriting must replace, not duplicate. A generic password is keyed by (account, service),
    /// so a second write with the same account has to update in place — otherwise the app
    /// accumulates items and reads whichever the keychain returns first, which is a session that
    /// works until it doesn't. A ratchet writes on every message, so this happens constantly.
    func testASecondWriteReplacesTheFirst() {
        let first = Data(repeating: 0x01, count: 64)
        let second = Data(repeating: 0x02, count: 64)
        XCTAssertTrue(KeychainManager.shared.saveSessionData(first, for: contact))
        XCTAssertTrue(KeychainManager.shared.saveSessionData(second, for: contact))
        XCTAssertEqual(KeychainManager.shared.loadSessionData(for: contact), second,
                       "the first write is still being returned")
    }

    /// Deletion is real, not a tombstone the next read still finds.
    func testDeletionRemovesIt() {
        XCTAssertTrue(KeychainManager.shared.saveSessionData(Data([0xFF, 0xEE]), for: contact))
        XCTAssertNotNil(KeychainManager.shared.loadSessionData(for: contact))
        KeychainManager.shared.deleteSession(for: contact)
        XCTAssertNil(KeychainManager.shared.loadSessionData(for: contact))
    }

    /// **The divergence this target must not paper over.**
    ///
    /// `AGENTS.md` names an invariant: crypto state that must survive a background push decrypt on
    /// a locked device is written `kSecAttrAccessibleAfterFirstUnlock*`, never `WhenUnlocked*`, or
    /// a session desyncs silently. `saveSessionData` sets `AfterFirstUnlockThisDeviceOnly` for
    /// exactly that reason.
    ///
    /// The app sets no `kSecUseDataProtectionKeychain`, so on macOS it uses the **file-based**
    /// keychain, which accepts `kSecAttrAccessible` and does not store it. This test reads the
    /// stored attributes back and records which platform this is.
    ///
    /// The consequence is a scoping rule, not a bug: the Mac is a second device for fan-out,
    /// sender-sync and transcript convergence. It is **not** a stand-in for a locked iPhone waking
    /// on a push, and a green run here says nothing about that invariant.
    ///
    /// Pinned as a test rather than a comment so that if it ever changes — someone adds
    /// `kSecUseDataProtectionKeychain`, or the default moves — it is announced by a red test
    /// instead of by a session that stops decrypting on one platform.
    func testAccessibilityIsNotRecordedOnThisPlatform() throws {
        XCTAssertTrue(KeychainManager.shared.saveSessionData(Data([0xAB, 0xCD]), for: contact))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainSessionAccounts.account(for: contact),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "the item we just wrote is not findable by account alone")
        let attrs = try XCTUnwrap(item as? [String: Any])

        XCTAssertNil(
            attrs[kSecAttrAccessible as String],
            """
            macOS started recording kSecAttrAccessible. That is a behaviour change worth acting on: \
            it would mean the data-protection keychain is in use, and the Mac may now be able to \
            check the locked-device invariant it currently cannot. Re-read AGENTS.md's Keychain \
            rule before updating this test.
            """
        )
    }
}
