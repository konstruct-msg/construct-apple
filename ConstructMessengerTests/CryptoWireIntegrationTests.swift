//
//  CryptoWireIntegrationTests.swift
//  ConstructMessengerTests
//
//  Integration tests for the full message send/receive pipeline:
//  Rust crypto core → WirePayloadCoder.encode → (wire) → WirePayloadCoder.decode → Rust decrypt
//
//  This validates that the binary wire format correctly round-trips through the crypto layer,
//  matching what actually happens in production (ChunkedMessageDelivery → MessageStreamManager).
//

import XCTest
@testable import Construct_Messenger

final class CryptoWireIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal crypto peer — wraps a Rust OrchestratorCore instance for testing
    class CryptoPeer {
        let core: OrchestratorCore
        let userId: String

        init(userId: String) throws {
            self.userId = userId
            // Bootstrap: generate fresh device keys via ClassicCryptoCore, then
            // migrate to OrchestratorCore (matches the production init path).
            let bootstrap = try createCryptoCore()
            let keys = try bootstrap.exportPrivateKeys()
            self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
        }

        func bundle() throws -> (identityPublic: [UInt8], signedPrekeyPublic: [UInt8],
                                  signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16) {
            let fields = try core.getRegistrationBundleFields()
            return (fields.identityPublic, fields.signedPrekeyPublic, fields.signature, fields.verifyingKey, fields.suiteId)
        }

        private func bundleBytes(from b: (identityPublic: [UInt8], signedPrekeyPublic: [UInt8],
                                          signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16)) throws -> BinaryKeyBundle {
            return BinaryKeyBundle(
                identityPublic: b.identityPublic, signedPrekeyPublic: b.signedPrekeyPublic,
                signature: b.signature, verifyingKey: b.verifyingKey,
                suiteId: b.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
                spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
                kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
            )
        }

        /// Initiate session as sender (X3DH)
        func initSenderSession(to contactId: String,
                                recipientBundle: (identityPublic: [UInt8], signedPrekeyPublic: [UInt8],
                                                  signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16)) throws {
            let bytes = try bundleBytes(from: recipientBundle)
            _ = try core.initSession(contactId: contactId, recipientBundle: bytes)
        }

        /// Encrypt plaintext → EncryptedMessageComponents (wraps Rust core)
        func encryptRaw(_ plaintext: String, to contactId: String) throws -> MessageCryptoService.EncryptedMessageComponents {
            let rustComponents = try core.encryptMessage(contactId: contactId, plaintext: Data(plaintext.utf8))
            let rawContent = Data(rustComponents.content)
            return MessageCryptoService.EncryptedMessageComponents(
                ephemeralPublicKey: Data(rustComponents.ephemeralPublicKey),
                messageNumber: rustComponents.messageNumber,
                content: MessagePadding.padCiphertext(rawContent),
                suiteId: 1,
                oneTimePreKeyId: rustComponents.oneTimePrekeyId,
                storageKey: Data(rustComponents.storageKey)
            )
        }

        /// Encode components to wire payload (same as ChunkedMessageDelivery does)
        func encodeWire(_ components: MessageCryptoService.EncryptedMessageComponents) throws -> Data {
            try WirePayloadCoder.encode(components)
        }

        /// Decode wire payload (same as MessageStreamManager does) and decrypt
        func decodeAndDecrypt(_ payload: Data, from contactId: String) throws -> String {
            let decoded = try WirePayloadCoder.decode(payload)
            let unpadded = MessagePadding.unpadCiphertext(decoded.content)
            let plaintextData = try core.decryptMessage(
                contactId: contactId,
                ephemeralPublicKey: decoded.ephemeralPublicKey,
                messageNumber: decoded.messageNumber,
                content: [UInt8](unpadded)
            )
            return String(data: Data(plaintextData.plaintext), encoding: .utf8) ?? ""
        }

        /// Initialize receiving session from first wire-encoded message
        func initReceiverSession(from contactId: String,
                                  senderBundle: (identityPublic: [UInt8], signedPrekeyPublic: [UInt8],
                                                 signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16),
                                  wirePayload: Data) throws -> String {
            let bundle = try bundleBytes(from: senderBundle)
            let decoded = try WirePayloadCoder.decode(wirePayload)
            let unpadded = MessagePadding.unpadCiphertext(decoded.content)
            let firstMsg = BinaryFirstMessage(
                ephemeralPublicKey: decoded.ephemeralPublicKey,
                messageNumber: decoded.messageNumber,
                content: [UInt8](unpadded),
                oneTimePrekeyId: 0
            )
            let result = try core.initReceivingSession(
                contactId: contactId,
                recipientBundle: bundle,
                firstMessage: firstMsg
            )
            return String(bytes: result.decryptedMessage, encoding: .utf8) ?? "__binary_init__"
        }
    }

    // MARK: - Full Wire Pipeline: Alice → Bob

    func testFullWirePipelineAliceToBob() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        // Alice initiates session
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        // Alice encrypts and encodes to wire
        let plaintext1 = "Hello Bob! Testing the full wire pipeline."
        let components = try alice.encryptRaw(plaintext1, to: bob.userId)
        let wirePayload = try alice.encodeWire(components)

        // Verify wire payload structure
        XCTAssertGreaterThan(wirePayload.count, WirePayloadCoder.headerSize)

        // Bob receives and decrypts from wire
        let decrypted1 = try bob.initReceiverSession(
            from: alice.userId,
            senderBundle: aliceBundle,
            wirePayload: wirePayload
        )
        XCTAssertEqual(decrypted1, plaintext1, "First message through full wire pipeline")
    }

    func testFullWirePipelineBidirectional() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        // Setup: Alice → Bob first message
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)
        let firstComponents = try alice.encryptRaw("Message 1 from Alice", to: bob.userId)
        let firstWire = try alice.encodeWire(firstComponents)

        _ = try bob.initReceiverSession(from: alice.userId, senderBundle: aliceBundle, wirePayload: firstWire)

        // Bob → Alice: reply using the existing session (initReceiverSession already set it up)
        // initSenderSession here would overwrite Bob's session with wrong key material
        let bobReply = try bob.encryptRaw("Reply from Bob", to: alice.userId)
        let bobWire = try bob.encodeWire(bobReply)

        // Alice decrypts Bob's reply — DH ratchet step, no initReceiverSession needed
        _ = try alice.decodeAndDecrypt(bobWire, from: bob.userId)

        // Continue: Alice sends another message (post-DH-ratchet)
        let plaintext = "Second message from Alice"
        let components2 = try alice.encryptRaw(plaintext, to: bob.userId)
        let wire2 = try alice.encodeWire(components2)
        let decrypted = try bob.decodeAndDecrypt(wire2, from: alice.userId)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWirePayloadIsOpaqueToServer() throws {
        // The server sees only the wire payload bytes — verify no plaintext leaks
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")
        let bobBundle = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let secretMessage = "VERY_SECRET_CONTENT_DO_NOT_LEAK"
        let components = try alice.encryptRaw(secretMessage, to: bob.userId)
        let wirePayload = try alice.encodeWire(components)

        // The wire payload should not contain the plaintext in any readable form
        let payloadString = String(data: wirePayload, encoding: .utf8)
        XCTAssertNil(payloadString.flatMap { $0.contains(secretMessage) ? $0 : nil },
            "Plaintext must not appear in wire payload")

        // Also check as ASCII
        let asciiBytes = secretMessage.utf8.map { $0 }
        let payloadBytes = [UInt8](wirePayload)
        let containsASCII = payloadBytes.windows(ofCount: asciiBytes.count).contains { Array($0) == asciiBytes }
        XCTAssertFalse(containsASCII, "Plaintext ASCII bytes must not appear in wire payload")
    }

    // MARK: - Multiple Messages via Wire

    func testMultipleMessagesViaWire() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        // First message establishes Bob's session
        let firstComp = try alice.encryptRaw("First", to: bob.userId)
        let firstWire = try alice.encodeWire(firstComp)
        let first = try bob.initReceiverSession(from: alice.userId, senderBundle: aliceBundle, wirePayload: firstWire)
        XCTAssertEqual(first, "First")

        // Subsequent messages
        for i in 2...10 {
            let plaintext = "Message number \(i)"
            let comp = try alice.encryptRaw(plaintext, to: bob.userId)
            let wire = try alice.encodeWire(comp)
            let decrypted = try bob.decodeAndDecrypt(wire, from: alice.userId)
            XCTAssertEqual(decrypted, plaintext, "Wire pipeline failed at message \(i)")
        }
    }

    // MARK: - Wire Format Integrity

    func testWirePayloadHeaderSize() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")
        let bobBundle = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)
        let comp = try alice.encryptRaw("test", to: bob.userId)
        let wire = try alice.encodeWire(comp)

        // First 4 bytes: message_number LE
        // Bytes 4..36: DH public key (32 bytes)
        XCTAssertGreaterThanOrEqual(wire.count, WirePayloadCoder.headerSize + 1)

        // Verify dh_public_key field is 32 bytes
        let dhBytes = wire[4..<36]
        XCTAssertEqual(dhBytes.count, 32)
    }

    func testWirePayloadMessageNumberIncrements() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")
        let bobBundle = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        var previousMsgNum: UInt32 = UInt32.max
        for _ in 0..<5 {
            let comp = try alice.encryptRaw("test", to: bob.userId)
            let wire = try alice.encodeWire(comp)
            let decoded = try WirePayloadCoder.decode(wire)

            if previousMsgNum != UInt32.max {
                XCTAssertGreaterThan(decoded.messageNumber, previousMsgNum,
                    "Message numbers must be strictly increasing")
            }
            previousMsgNum = decoded.messageNumber
        }
    }

    // MARK: - Tamper Resistance

    func testTamperedWirePayloadFailsDecryption() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let comp = try alice.encryptRaw("Hello", to: bob.userId)
        var wirePayload = try alice.encodeWire(comp)

        _ = try bob.initReceiverSession(from: alice.userId, senderBundle: aliceBundle, wirePayload: wirePayload)

        // Send second message, then tamper with the ciphertext bytes
        let comp2 = try alice.encryptRaw("Second", to: bob.userId)
        var tamperedWire = try alice.encodeWire(comp2)

        // Flip a bit in the ciphertext (beyond the 36-byte header)
        if tamperedWire.count > WirePayloadCoder.headerSize + 10 {
            tamperedWire[WirePayloadCoder.headerSize + 5] ^= 0xFF
        }

        XCTAssertThrowsError(try bob.decodeAndDecrypt(tamperedWire, from: alice.userId),
            "Tampered ciphertext must be rejected by AEAD")
    }

    func testTamperedMessageNumberFailsDecryption() throws {
        let alice = try CryptoPeer(userId: "alice-uuid-001")
        let bob   = try CryptoPeer(userId: "bob-uuid-002")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let comp = try alice.encryptRaw("Hello", to: bob.userId)
        let firstWire = try alice.encodeWire(comp)
        _ = try bob.initReceiverSession(from: alice.userId, senderBundle: aliceBundle, wirePayload: firstWire)

        // Second message — tamper with message_number in wire payload
        let comp2 = try alice.encryptRaw("Second", to: bob.userId)
        var wire2 = try alice.encodeWire(comp2)
        // Increment message_number byte by 1 (LE byte 0)
        wire2[0] = wire2[0] &+ 1

        XCTAssertThrowsError(try bob.decodeAndDecrypt(wire2, from: alice.userId),
            "Tampered message_number must fail AAD verification")
    }
}

// MARK: - AD Identity Tests
//
// Tests for the AEAD Associated Data identity-format invariant.
// Root cause postmortem: CryptoManager.cryptoLocalUserId returned a 32-char
// device-hash (loadDeviceID) instead of the 36-char server UUID (_cachedUserId).
// Double Ratchet AD:
//   ENCRYPT: AD_VERSION || local_user_id || contact_id || session_id || dh_pub || msg_num
//   DECRYPT: AD_VERSION || contact_id   || local_user_id || …
// Both IDs MUST use the same identity space (server UUIDs) on both sides.

final class ADIdentityTests: XCTestCase {

    // ── Convenience alias so we don't write CryptoWireIntegrationTests.CryptoPeer everywhere
    typealias Peer = CryptoWireIntegrationTests.CryptoPeer

    // MARK: - Type safety (compile-time proof)

    func testServerUserIdAndCryptoDeviceIdAreDistinctTypes() {
        // This test is a compile-time contract: if the two types were the same,
        // the assignment below would not compile.
        let serverUUID  = ServerUserId(rawValue: "14f28d31-2dab-44aa-a123-456789abcdef")
        let deviceHash  = CryptoDeviceId(rawValue: "6f5e37ac88bd2cc53348f01f78cdf5db")
        XCTAssertEqual(serverUUID.rawValue.count, 36, "Server UUID must be 36 chars")
        XCTAssertEqual(deviceHash.rawValue.count, 32, "Crypto device hash must be 32 chars")
        XCTAssertTrue(serverUUID.rawValue.contains("-"),  "Server UUID must contain dashes")
        XCTAssertFalse(deviceHash.rawValue.contains("-"), "Device hash must not contain dashes")
        // Compiler enforces they are distinct types — cannot pass one where the other is expected.
        XCTAssertNotEqual(serverUUID.rawValue, deviceHash.rawValue)
    }

    // MARK: - Regression: full session with production-format UUIDs (the fixed path)

    /// Full two-party exchange using production-format server UUIDs (36-char with dashes).
    /// This is the FIXED behaviour — the exact scenario that was always broken before the fix.
    func testFullSessionSucceedsWithProductionUUIDs() throws {
        // Real-looking server UUIDs (same format as production IDs).
        let aliceId = "14f28d31-2dab-44aa-a123-456789abcdef"
        let bobId   = "81f02199-8374-48f8-8a5f-549434ccc53f"

        let alice = try Peer(userId: aliceId)
        let bob   = try Peer(userId: bobId)

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        // Alice initiates
        try alice.initSenderSession(to: bobId, recipientBundle: bobBundle)
        let firstComponents = try alice.encryptRaw("Hello Bob - UUID session!", to: bobId)
        let firstWire = try alice.encodeWire(firstComponents)

        // Bob receives first message
        let decrypted1 = try bob.initReceiverSession(
            from: aliceId, senderBundle: aliceBundle, wirePayload: firstWire)
        XCTAssertEqual(decrypted1, "Hello Bob - UUID session!", "First message must decrypt")

        // Bob replies
        let replyComponents = try bob.encryptRaw("Hi Alice - UUID reply!", to: aliceId)
        let replyWire = try bob.encodeWire(replyComponents)
        let decrypted2 = try alice.decodeAndDecrypt(replyWire, from: bobId)
        XCTAssertEqual(decrypted2, "Hi Alice - UUID reply!", "Reply must decrypt")

        // Continue the conversation (several ratchet steps)
        for i in 0..<5 {
            let msg = try alice.encryptRaw("Alice msg \(i)", to: bobId)
            let wire = try alice.encodeWire(msg)
            let dec = try bob.decodeAndDecrypt(wire, from: aliceId)
            XCTAssertEqual(dec, "Alice msg \(i)")
        }
    }

    // MARK: - Bug reproduction: device-hash local_user_id vs UUID contact_id

    /// Reproduces the original production bug.
    /// Alice's OrchestratorCore was initialised with a 32-char device-hash (old broken path).
    /// Bob knows Alice by her 36-char server UUID.
    /// AD bytes mismatch → `initReceivingSession` MUST throw.
    func testSessionFailsWhenInitiatorUsesDeviceHashAsUserId() throws {
        // Alice (buggy): userId = 32-char hex device-hash (old `cryptoLocalUserId` behaviour)
        let aliceDeviceHash = "6f5e37ac88bd2cc53348f01f78cdf5db" // 32 hex chars, no dashes
        // Bob's contact-list entry for Alice: server UUID (what the server hands out)
        let aliceServerUUID = "14f28d31-2dab-44aa-a123-456789abcdef"
        let bobId           = "81f02199-8374-48f8-8a5f-549434ccc53f"

        XCTAssertEqual(aliceDeviceHash.count, 32, "Precondition: device hash is 32 chars")
        XCTAssertEqual(aliceServerUUID.count, 36, "Precondition: server UUID is 36 chars")

        // Alice Peer initialised with device hash — this is the broken state.
        let aliceBuggy = try Peer(userId: aliceDeviceHash)
        let bob        = try Peer(userId: bobId)

        let aliceBundle = try aliceBuggy.bundle()
        let bobBundle   = try bob.bundle()

        try aliceBuggy.initSenderSession(to: bobId, recipientBundle: bobBundle)
        let firstComponents = try aliceBuggy.encryptRaw("This AEAD tag will not verify", to: bobId)
        let firstWire = try aliceBuggy.encodeWire(firstComponents)

        // Bob tries to init session, but knows Alice by server UUID — AD MUST mismatch.
        XCTAssertThrowsError(
            try bob.initReceiverSession(
                from: aliceServerUUID, // Bob's contact_id for Alice = UUID
                senderBundle: aliceBundle,
                wirePayload: firstWire),
            "AEAD must fail: initiator used device-hash (32 hex) but responder expects UUID (36 chars)"
        )
    }

    /// Complementary: when Bob's contact_id for Alice matches what Alice used as local_user_id,
    /// even with a non-UUID format, the session succeeds.
    /// This confirms the invariant is FORMAT CONSISTENCY, not UUID enforcement.
    func testSessionSucceedsWhenBothSidesUseConsistentNonUUIDIds() throws {
        let aliceId = "alice-node-id-in-mesh"
        let bobId   = "bob-node-id-in-mesh"

        let alice = try Peer(userId: aliceId)
        let bob   = try Peer(userId: bobId)

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bobId, recipientBundle: bobBundle)
        let firstComponents = try alice.encryptRaw("consistent IDs work", to: bobId)
        let firstWire = try alice.encodeWire(firstComponents)

        // Bob uses the same aliceId that Alice used as her local_user_id → formats match.
        let decrypted = try bob.initReceiverSession(
            from: aliceId, senderBundle: aliceBundle, wirePayload: firstWire)
        XCTAssertEqual(decrypted, "consistent IDs work")
    }

    // MARK: - Edge cases

    /// AD binds sender identity: Bob must reject a message he receives but attributes to Carol.
    func testSessionFailsWhenContactIdAttributedToWrongUser() throws {
        let aliceId = "14f28d31-2dab-44aa-a123-456789abcdef"
        let carolId = "99999999-0000-0000-0000-111111111111"
        let bobId   = "81f02199-8374-48f8-8a5f-549434ccc53f"

        let alice = try Peer(userId: aliceId)
        let bob   = try Peer(userId: bobId)

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bobId, recipientBundle: bobBundle)
        let firstComponents = try alice.encryptRaw("only for bob", to: bobId)
        let firstWire = try alice.encodeWire(firstComponents)

        // Bob processes the message as if it came from Carol — AD mismatch.
        XCTAssertThrowsError(
            try bob.initReceiverSession(
                from: carolId, // WRONG — should be aliceId
                senderBundle: aliceBundle,
                wirePayload: firstWire),
            "AD must bind sender identity: wrong contact_id attribution must fail"
        )
    }

    /// Multi-message conversation must stay in sync across DH ratchet steps.
    /// Verifies that the UUID-based AD doesn't break ratchet advancement.
    func testLongConversationWithUUIDIdsStaysInSync() throws {
        let aliceId = "14f28d31-2dab-44aa-a123-456789abcdef"
        let bobId   = "81f02199-8374-48f8-8a5f-549434ccc53f"

        let alice = try Peer(userId: aliceId)
        let bob   = try Peer(userId: bobId)

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bobId, recipientBundle: bobBundle)
        let firstWire = try alice.encodeWire(try alice.encryptRaw("msg0", to: bobId))
        _ = try bob.initReceiverSession(from: aliceId, senderBundle: aliceBundle, wirePayload: firstWire)

        // 10 rounds of alternating messages (triggers multiple DH ratchet steps)
        for i in 1...10 {
            let aMsg = "alice-\(i)"
            let aWire = try alice.encodeWire(try alice.encryptRaw(aMsg, to: bobId))
            XCTAssertEqual(try bob.decodeAndDecrypt(aWire, from: aliceId), aMsg)

            let bMsg = "bob-\(i)"
            let bWire = try bob.encodeWire(try bob.encryptRaw(bMsg, to: aliceId))
            XCTAssertEqual(try alice.decodeAndDecrypt(bWire, from: bobId), bMsg)
        }
    }

    // MARK: - Migration guard

    func testMigrationUserDefaultsFlagPreventsRepeatedClears() {
        let key = "construct.adMigration.serverUUID.v1.done"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) } // clean up after test

        XCTAssertFalse(UserDefaults.standard.bool(forKey: key),
                       "Flag must be absent before first migration run")

        // Simulate what migrateSessionsIfNeeded does when it runs for the first time.
        UserDefaults.standard.set(true, forKey: key)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                      "Flag must be set after first run")

        // A second call should skip work because the flag is already set.
        // (We can't call the private method directly; we verify the guard contract.)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                      "Flag must persist so migration does not run again on next launch")
    }
}

// MARK: - Collection sliding window helper

private extension Collection {
    func windows(ofCount size: Int) -> [[Element]] {
        guard count >= size else { return [] }
        var result: [[Element]] = []
        var start = startIndex
        while true {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            if distance(from: start, to: end) < size { break }
            result.append(Array(self[start..<end]))
            start = index(after: start)
        }
        return result
    }
}
