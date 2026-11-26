import LocalAuthentication
import Security
import XCTest
@testable import Construct_Messenger

/// A Keychain listing never reaches the recovery phrase held behind `.userPresence`. On a device
/// that reach asks for Face ID or the passcode, synchronously; at launch it is the main thread
/// during scene creation, and the watchdog kills the app (the 2026-11-26 iPad, white screen).
final class KeychainListingTests: XCTestCase {
    private let prefix = "test.keychain.listing."
    private var guarded: String { prefix + "guarded" }
    private var plain: String { prefix + "plain" }

    override func tearDown() {
        for account in [guarded, plain] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        super.tearDown()
    }

    private var listedClasses: [String] {
        KeychainManager.listingQueries().compactMap { $0[kSecAttrAccessible as String] as? String }
    }

    func testEveryListingNamesAClassAndNoneIsThePhrasesClass() {
        XCTAssertEqual(listedClasses.count, KeychainManager.listingQueries().count,
                       "a query without a class matches every item, the phrase too")
        XCTAssertFalse(listedClasses.contains(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String))
    }

    func testTheClassesThisAppWritesAreListed() {
        XCTAssertTrue(listedClasses.contains(KeychainManager.cryptoKeyAccessible as String),
                      "sessions are written with it; a listing without it finds no session")
        XCTAssertTrue(listedClasses.contains(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
                      "saveData's default")
    }

    func testEveryListingForbidsAPrompt() {
        for query in KeychainManager.listingQueries() {
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            XCTAssertEqual(context?.interactionNotAllowed, true)
        }
    }

    /// The simulator lists an item behind user presence without asking, so here the effect is
    /// "not listed", not "no prompt".
    func testThePurgeLeavesTheItemBehindUserPresenceAlone() throws {
        let access = try XCTUnwrap(SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil))
        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: guarded,
            kSecValueData as String: Data([7]),
            kSecAttrAccessControl as String: access
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "this simulator cannot hold an item behind user presence (\(added))")
        XCTAssertTrue(KeychainManager.shared.saveData(Data([1]), forKey: plain))

        XCTAssertEqual(KeychainManager.shared.deleteItems(withAccountPrefix: prefix), 1,
                       "only the app's own item is listed")

        let context = LAContext()
        context.interactionNotAllowed = true
        let left = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: guarded,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context
        ] as CFDictionary, nil)
        XCTAssertEqual(left, errSecSuccess, "the item behind user presence is still there")
        XCTAssertNil(KeychainManager.shared.loadData(forKey: plain))
    }
}
