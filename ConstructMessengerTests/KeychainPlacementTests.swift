//
//  KeychainPlacementTests.swift
//  ConstructMessengerTests
//
//  The read decision behind the Mac's move to the data protection keychain. The claims that
//  cost an account when wrong: an empty answer from a keychain this build cannot use is not
//  "never registered", and a copy that could not be read or written stays where it is.
//

import XCTest
import Security
@testable import Construct_Messenger

final class KeychainPlacementTests: XCTestCase {

    private let value = KeychainRead.found(Data([7, 7]))

    private func read(current: KeychainRead, usable: Bool = true, hasLegacy: Bool = true,
                      legacy: KeychainRead, consulted: inout Bool) -> KeychainPlacement.ReadOutcome {
        var asked = false
        let outcome = KeychainPlacement.read(current: current, currentUsable: usable, hasLegacy: hasLegacy) {
            asked = true
            return legacy
        }
        consulted = asked
        return outcome
    }

    func testAnItemAlreadyMovedIsReadWithoutTouchingTheLoginKeychain() {
        var consulted = false
        let outcome = read(current: value, legacy: .found(Data([1])), consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: value, moveFromLegacy: false))
        XCTAssertFalse(consulted, "reading the login keychain is what puts up the prompt")
    }

    func testAnUnreadableItemIsNotOverruledByAnOlderCopy() {
        var consulted = false
        let outcome = read(current: .unreadable(errSecInteractionNotAllowed), legacy: value, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: .unreadable(errSecInteractionNotAllowed), moveFromLegacy: false))
        XCTAssertFalse(consulted)
    }

    func testAnItemStillInTheLoginKeychainIsAnsweredAndMoves() {
        var consulted = false
        let outcome = read(current: .absent, legacy: value, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: value, moveFromLegacy: true))
        XCTAssertTrue(consulted)
    }

    func testWithoutTheEntitlementTheOldCopyIsReadButStays() {
        var consulted = false
        let outcome = read(current: .absent, usable: false, legacy: value, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: value, moveFromLegacy: false))
    }

    func testAbsentFromBothIsAbsent() {
        var consulted = false
        let outcome = read(current: .absent, legacy: .absent, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: .absent, moveFromLegacy: false))
    }

    /// A build without the access group reads `errSecItemNotFound` from the data protection
    /// keychain whatever it holds. Answering "absent" would make a registered Mac look new.
    func testAbsentFromAKeychainThisBuildCannotUseIsUnreadable() {
        var consulted = false
        let outcome = read(current: .absent, usable: false, legacy: .absent, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: .unreadable(errSecMissingEntitlement), moveFromLegacy: false))
        XCTAssertFalse(outcome.answer.isAbsent)
    }

    func testARefusedLoginKeychainReadIsUnreadableAndNothingMoves() {
        var consulted = false
        let outcome = read(current: .absent, legacy: .unreadable(errSecAuthFailed), consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: .unreadable(errSecAuthFailed), moveFromLegacy: false))
    }

    func testWithOneKeychainTheLoginKeychainIsNeverAsked() {
        var consulted = false
        let outcome = read(current: .absent, hasLegacy: false, legacy: value, consulted: &consulted)
        XCTAssertEqual(outcome, .init(answer: .absent, moveFromLegacy: false))
        XCTAssertFalse(consulted)
    }

    func testIOSQueriesAreLeftAsTheyWere() {
        let query: [String: Any] = [kSecAttrAccount as String: "a"]
        XCTAssertFalse(KeychainPlacement.hasLegacyKeychain)
        XCTAssertNil(KeychainPlacement.current(query)[kSecUseDataProtectionKeychain as String])
        XCTAssertTrue(KeychainPlacement.isCurrentUsable)
    }
}
