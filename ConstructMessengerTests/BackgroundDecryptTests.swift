//
//  BackgroundDecryptTests.swift
//  ConstructMessengerTests
//
//  Regression tests for the background-decrypt safety invariant:
//
//  Rule: a failed decryptOfflineBatch MUST NOT archive (wipe) the DR session.
//  The foreground stream owns session recovery (END_SESSION / healing).
//  If background failures archived sessions, a stale push or a duplicate message
//  would silently destroy a healthy session and break all subsequent messages.
//

import XCTest
@testable import Construct_Messenger

final class BackgroundDecryptTests: XCTestCase {

    // MARK: - Minimal peer helper (matches CryptoPeer in CryptoWireIntegrationTests)

    private final class Peer {
        let core: OrchestratorCore
        let userId: String

        init(userId: String) throws {
            self.userId = userId
            let bootstrap = try createCryptoCore()
            let keys = try bootstrap.exportPrivateKeys()
            self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
        }

        func rawBundle() throws -> (ip: [UInt8], sp: [UInt8], sig: [UInt8], vk: [UInt8], suiteId: UInt16) {
            let f = try core.getRegistrationBundleFields()
            return (f.identityPublic, f.signedPrekeyPublic, f.signature, f.verifyingKey, f.suiteId)
        }

        func binaryBundle() throws -> BinaryKeyBundle {
            let b = try rawBundle()
            return BinaryKeyBundle(
                identityPublic: b.ip, signedPrekeyPublic: b.sp,
                signature: b.sig, verifyingKey: b.vk,
                suiteId: b.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
                spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
                kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
            )
        }

        /// Alice path: init sender session → encrypt first message → return wire payload.
        func initAndEncryptFirst(_ plaintext: String, to contact: Peer) throws -> Data {
            let bundle = try contact.binaryBundle()
            _ = try core.initSession(contactId: contact.userId, recipientBundle: bundle)
            let comps = try core.encryptMessage(contactId: contact.userId, plaintext: Data(plaintext.utf8))
            let swiftComps = MessageCryptoService.EncryptedMessageComponents(
                ephemeralPublicKey: Data(comps.ephemeralPublicKey),
                messageNumber: comps.messageNumber,
                content: MessagePadding.padCiphertext(Data(comps.content)),
                suiteId: 1,
                oneTimePreKeyId: comps.oneTimePrekeyId,
                storageKey: Data(comps.storageKey)
            )
            return try WirePayloadCoder.encode(swiftComps)
        }

        /// Bob path: establish receiving session from a wire payload + sender's binary bundle.
        func initReceiver(from sender: Peer, wirePayload: Data) throws {
            let bundle = try sender.binaryBundle()
            let decoded = try WirePayloadCoder.decode(wirePayload)
            let unpadded = MessagePadding.unpadCiphertext(decoded.content)
            let firstMsg = BinaryFirstMessage(
                ephemeralPublicKey: decoded.ephemeralPublicKey,
                messageNumber: decoded.messageNumber,
                content: [UInt8](unpadded),
                oneTimePrekeyId: 0
            )
            _ = try core.initReceivingSession(
                contactId: sender.userId,
                recipientBundle: bundle,
                firstMessage: firstMsg
            )
        }

        /// Encrypt a subsequent message (after session established) and return raw components.
        func encryptNext(_ plaintext: String, to contactId: String) throws -> EncryptedMessageComponents {
            try core.encryptMessage(contactId: contactId, plaintext: Data(plaintext.utf8))
        }

        /// Decrypt via the background batch path.
        func batchDecrypt(messages: [OfflineBatchMessage]) -> [OfflineBatchResult] {
            core.decryptOfflineBatch(messages: messages)
        }

        /// Decrypt via the normal foreground path (verifies session health post-batch).
        func decryptViaWire(_ wirePayload: Data, from contactId: String) throws -> String {
            let decoded = try WirePayloadCoder.decode(wirePayload)
            let unpadded = MessagePadding.unpadCiphertext(decoded.content)
            let result = try core.decryptMessage(
                contactId: contactId,
                ephemeralPublicKey: decoded.ephemeralPublicKey,
                messageNumber: decoded.messageNumber,
                content: [UInt8](unpadded)
            )
            return String(data: Data(result.plaintext), encoding: .utf8) ?? "__binary__"
        }
    }

    // MARK: - Tests

    /// Core invariant: failed decryptOfflineBatch preserves session.
    ///
    /// 1. Alice and Bob establish a session.
    /// 2. Alice encrypts a second message (message 2).
    /// 3. The content of that message is corrupted before passing to Bob's batch decrypt.
    /// 4. Verifies: error returned, no plaintext, session still healthy afterwards.
    /// 5. Bob can still decrypt a later valid message — DR state was not corrupted.
    func testBatchDecryptFailurePreservesSession() throws {
        let alice = try Peer(userId: "alice-\(UUID().uuidString)")
        let bob   = try Peer(userId: "bob-\(UUID().uuidString)")

        // ── Establish session: Alice → Bob ─────────────────────────────────────
        let firstWire = try alice.initAndEncryptFirst("ping", to: bob)
        try bob.initReceiver(from: alice, wirePayload: firstWire)

        XCTAssertTrue(bob.core.hasSession(contactId: alice.userId),
                      "session must exist after init")

        // ── Alice encrypts message 2 ───────────────────────────────────────────
        let enc2 = try alice.encryptNext("sensitive data", to: bob.userId)

        // ── Corrupt the ciphertext ─────────────────────────────────────────────
        let corrupt = OfflineBatchMessage(
            id: UUID().uuidString,
            contactId: alice.userId,
            ephemeralPublicKey: enc2.ephemeralPublicKey,
            messageNumber: enc2.messageNumber,
            content: [UInt8](repeating: 0xFF, count: max(64, enc2.content.count))
        )

        // ── Batch decrypt (background path) ───────────────────────────────────
        let results = bob.batchDecrypt(messages: [corrupt])

        XCTAssertEqual(results.count, 1, "should return one result per input message")
        XCTAssertNil(results[0].plaintext, "corrupted message must not decrypt")
        XCTAssertNotNil(results[0].error, "must have an error string on failure")

        // ── Session MUST still exist ────────────────────────────────────────────
        XCTAssertTrue(bob.core.hasSession(contactId: alice.userId),
                      "session MUST be preserved after batch decrypt failure")

        // ── Subsequent valid message must still decrypt ─────────────────────────
        let enc3 = try alice.encryptNext("still works", to: bob.userId)
        let swiftComps3 = MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: Data(enc3.ephemeralPublicKey),
            messageNumber: enc3.messageNumber,
            content: MessagePadding.padCiphertext(Data(enc3.content)),
            suiteId: 1,
            oneTimePreKeyId: enc3.oneTimePrekeyId,
            storageKey: Data(enc3.storageKey)
        )
        let wire3 = try WirePayloadCoder.encode(swiftComps3)
        let decrypted3 = try bob.decryptViaWire(wire3, from: alice.userId)

        XCTAssertEqual(decrypted3, "still works",
                       "session must remain functional after a failed batch decrypt")
    }

    /// Multiple corrupted messages in a single batch — all fail, session survives every one.
    func testBatchDecryptMultipleFailuresPreservesSession() throws {
        let alice = try Peer(userId: "alice-\(UUID().uuidString)")
        let bob   = try Peer(userId: "bob-\(UUID().uuidString)")

        let firstWire = try alice.initAndEncryptFirst("ping", to: bob)
        try bob.initReceiver(from: alice, wirePayload: firstWire)

        let enc = try alice.encryptNext("msg", to: bob.userId)

        let badMessages = (0..<5).map { _ in
            OfflineBatchMessage(
                id: UUID().uuidString,
                contactId: alice.userId,
                ephemeralPublicKey: enc.ephemeralPublicKey,
                messageNumber: enc.messageNumber,
                content: [UInt8](repeating: 0xAB, count: 64)
            )
        }

        let results = bob.batchDecrypt(messages: badMessages)
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.plaintext == nil }, "no result should succeed")
        XCTAssertTrue(results.allSatisfy { $0.error != nil }, "all results must carry an error")
        XCTAssertTrue(bob.core.hasSession(contactId: alice.userId),
                      "session must survive 5 consecutive batch failures")
    }
}
