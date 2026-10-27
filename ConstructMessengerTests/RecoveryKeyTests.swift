//
//  RecoveryKeyTests.swift
//  ConstructMessengerTests
//
//  The hybrid recovery key on the real core (construct-core 0.59.0): the phrase keeps the address
//  it always had, a claim is bound to the device it names, and the one account state that asks
//  for the phrase. construct-docs todo/222-recovery-key-hybrid-pq.md. Each test names the mutation
//  that reddens it.
//
//  The Ed25519 half of a hybrid signature is deterministic, so signing the same fields twice gives
//  the same 64 bytes and signing other fields does not — that is how a test sees what was signed
//  without rebuilding the bytes the core signs.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class RecoveryKeyTests: XCTestCase {

    private let phrase =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    /// This phrase's Ed25519 recovery key, computed outside the core (construct-core's
    /// `TEST_ED25519_PUBLIC`, from Python): the address every account made from it has.
    private let legacyKeyHex = "7c2e79f3a1701fb2a86a2c24a3fdf8634b7aad80886c0c0a526d44d23fe8e19a"
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func ed25519Half(_ signed: RecoveryKey.Signed) -> Data {
        Data(signed.signature.prefix(64))
    }

    /// The address is the key's Ed25519 half — the key the phrase always gave.
    ///
    /// Mutation: `address(of:)` returns the whole hybrid key — this reddens.
    func testThePhraseKeepsTheAddressItAlwaysHad() throws {
        XCTAssertEqual(InviteBinaryCodec.hex(try RecoveryKey.address(phrase: phrase)), legacyKeyHex)
        let signed = try RecoveryKey.setup(phrase: phrase, accountId: "acct", at: moment)
        XCTAssertEqual(signed.publicKey.count, 32 + 1952)
        XCTAssertEqual(signed.signature.count, 64 + 3309)
        XCTAssertEqual(InviteBinaryCodec.hex(signed.address), legacyKeyHex)
        XCTAssertEqual(signed.timestamp, 1_800_000_000)
    }

    /// A setup names the account it is for.
    func testASetupIsForItsAccount() throws {
        let a = try RecoveryKey.setup(phrase: phrase, accountId: "acct", at: moment)
        let again = try RecoveryKey.setup(phrase: phrase, accountId: "acct", at: moment)
        let other = try RecoveryKey.setup(phrase: phrase, accountId: "other", at: moment)
        XCTAssertEqual(ed25519Half(a), ed25519Half(again))
        XCTAssertNotEqual(ed25519Half(a), ed25519Half(other))
    }

    /// A claim names the new device's id, verifying key and identity key: change any and the
    /// signature is another.
    ///
    /// Mutation: pass `verifyingKey` where `identityPublic` goes in `claim` — the identity key is
    /// no longer signed; this reddens.
    func testAClaimIsForTheDeviceItNames() throws {
        func claim(_ id: String, _ vk: UInt8, _ ik: UInt8) throws -> Data {
            ed25519Half(try RecoveryKey.claim(
                phrase: phrase,
                deviceId: id,
                verifyingKey: Data(repeating: vk, count: 32),
                identityPublic: Data(repeating: ik, count: 32),
                at: moment
            ))
        }
        let base = try claim("dev", 1, 2)
        XCTAssertEqual(base, try claim("dev", 1, 2))
        XCTAssertNotEqual(base, try claim("other", 1, 2), "device id not signed")
        XCTAssertNotEqual(base, try claim("dev", 9, 2), "verifying key not signed")
        XCTAssertNotEqual(base, try claim("dev", 1, 9), "identity key not signed")
    }

    func testAnInvalidPhraseSignsNothing() {
        XCTAssertThrowsError(try RecoveryKey.setup(phrase: "not a phrase", accountId: "acct"))
        XCTAssertThrowsError(try RecoveryKey.address(phrase: "not a phrase"))
    }

    /// The phrase is asked for only when the account's key is Ed25519 alone, and only once the
    /// status is known.
    ///
    /// Mutation: drop `!isHybrid` from `upgradeNeeded` — a hybrid account is asked; this reddens.
    func testOnlyAnEd25519AccountIsAskedForThePhrase() {
        let vm = AccountRecoveryViewModel()
        vm.isSetup = true
        vm.isHybrid = false
        XCTAssertFalse(vm.upgradeNeeded, "status not loaded yet")
        vm.statusLoaded = true
        XCTAssertTrue(vm.upgradeNeeded)
        vm.isHybrid = true
        XCTAssertFalse(vm.upgradeNeeded)
        vm.isHybrid = false
        vm.isSetup = false
        XCTAssertFalse(vm.upgradeNeeded, "no key at all is the setup, not the upgrade")
    }
}
