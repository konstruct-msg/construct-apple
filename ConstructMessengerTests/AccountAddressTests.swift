//
//  AccountAddressTests.swift
//  ConstructMessengerTests
//
//  The account address from both ends: how a sealed envelope names its recipient, and what this
//  device accepts as its own address. decisions/invite-carries-the-account-address.md
//

import XCTest
import CryptoKit
import SwiftProtobuf
@testable import Construct_Messenger

final class AccountAddressTests: XCTestCase {

    private let key = Data((0..<32).map { UInt8($0) })

    /// The form the server's `UserId::parse` reads. A different prefix or case is a recipient the
    /// server rejects as malformed.
    func testTheWireFormIsEd25519ColonLowercaseHex() {
        XCTAssertEqual(
            AccountAddress.wire(key),
            "ed25519:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
    }

    func testARecipientIsNamedByAddressWhenOneIsKnown() {
        XCTAssertEqual(
            AccountAddress.recipientField(accountId: "14f28d31-0000-0000-0000-000000000001", address: key),
            AccountAddress.wire(key)
        )
    }

    /// No address, or something that is not a key, falls back to the account id: a truncated key
    /// would be an address no account has, and the server drops those without a word.
    func testWithoutAUsableAddressTheAccountIdIsKept() {
        let id = "14f28d31-0000-0000-0000-000000000001"
        XCTAssertEqual(AccountAddress.recipientField(accountId: id, address: nil), id)
        XCTAssertEqual(AccountAddress.recipientField(accountId: id, address: Data(repeating: 1, count: 31)), id)
    }

    // MARK: - Confirming our own address

    /// The server's `key_fingerprint`: leading hex, uppercase, spaced groups of four.
    private func serverFingerprint(_ key: Data) -> String {
        let hex = key.map { String(format: "%02X", $0) }.joined().prefix(32)
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    func testTheServersFingerprintOfOurKeyMatches() {
        XCTAssertTrue(AccountAddress.matchesServerFingerprint(key, fingerprint: serverFingerprint(key)))
    }

    /// Mutation: return true unconditionally — a phrase from another account would then teach
    /// this device a foreign address, and every invite it mints would lose the replies.
    func testAnotherKeysFingerprintDoesNotMatch() {
        let other = Data(repeating: 0xEE, count: 32)
        XCTAssertFalse(AccountAddress.matchesServerFingerprint(key, fingerprint: serverFingerprint(other)))
    }

    /// A short fingerprint would let a handful of matching digits stand for the whole key.
    func testATruncatedFingerprintIsNotEnough() {
        XCTAssertFalse(AccountAddress.matchesServerFingerprint(key, fingerprint: "0001 0203"))
        XCTAssertFalse(AccountAddress.matchesServerFingerprint(key, fingerprint: ""))
    }

    // MARK: - Minting

    /// Without an address nothing is minted: an invite naming none would leave the redeemer
    /// writing to the server-assigned id, which is what the address exists to replace.
    ///
    /// Mutation: drop the guard in `InviteGenerator.generate` — this reddens.
    func testNoInviteIsMintedWithoutAnAddress() {
        let generator = InviteGenerator(accountAddress: { nil })
        XCTAssertThrowsError(
            try generator.generate(
                userId: "14f28d31-0000-0000-0000-000000000001",
                deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
                ttlSeconds: InviteConfig.qrTTLSeconds
            )
        ) { error in
            guard case InviteGenerationError.noAccountAddress = error else {
                return XCTFail("expected noAccountAddress, got \(error)")
            }
        }
    }
}

/// The sealed envelope names its recipient by address — and only that field moves.
@MainActor
final class SealedInnerRecipientAddressTests: XCTestCase {

    private let accountId = "14f28d31-0000-0000-0000-000000000002"
    private var savedLookup: ((String) -> Data?)!

    override func setUp() {
        super.setUp()
        savedLookup = StealthSenderService.shared.accountAddressLookup
    }

    override func tearDown() {
        StealthSenderService.shared.accountAddressLookup = savedLookup
        super.tearDown()
    }

    private func inner(address: Data?) async throws -> Shared_Proto_Core_V1_SealedInner {
        StealthSenderService.shared.accountAddressLookup = { _ in address }
        let bytes = try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: accountId,
            certBytes: Data([0x01, 0x02, 0x03]),
            recipientIdentityKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            encryptedPayload: Data([0xAA]),
            contentType: .generic
        )
        return try Shared_Proto_Core_V1_SealedInner(serializedBytes: bytes)
    }

    /// Mutation: write `recipientUserId` straight into the field again — this reddens.
    func testAKnownAddressNamesTheRecipient() async throws {
        let address = Data(repeating: 0x5A, count: 32)
        let named = try await inner(address: address).recipientUserID
        XCTAssertEqual(named, AccountAddress.wire(address))
    }

    func testAnUnknownAddressKeepsTheAccountId() async throws {
        let named = try await inner(address: nil).recipientUserID
        XCTAssertEqual(named, accountId)
    }
}
