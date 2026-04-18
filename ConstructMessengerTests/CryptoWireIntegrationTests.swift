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

        /// Export key bundle for X3DH
        func bundle() throws -> (identityPublic: String, signedPrekeyPublic: String,
                                  signature: String, verifyingKey: String, suiteId: String) {
            let json = try core.exportRegistrationBundleJson()
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = dict["identity_public"] as? String,
                  let sp = dict["signed_prekey_public"] as? String,
                  let sig = dict["signature"] as? String,
                  let vk = dict["verifying_key"] as? String,
                  let sid = dict["suite_id"] as? String else {
                throw NSError(domain: "TestError", code: 1)
            }
            return (ip, sp, sig, vk, sid)
        }

        private func bundleBytes(from b: (identityPublic: String, signedPrekeyPublic: String,
                                          signature: String, verifyingKey: String, suiteId: String)) throws -> [UInt8] {
            guard let ip = Data(base64Encoded: b.identityPublic),
                  let sp = Data(base64Encoded: b.signedPrekeyPublic),
                  let sig = Data(base64Encoded: b.signature),
                  let vk = Data(base64Encoded: b.verifyingKey),
                  let sid = UInt16(b.suiteId) else {
                throw NSError(domain: "TestError", code: 2)
            }
            let dict: [String: Any] = [
                "identity_public": [UInt8](ip),
                "signed_prekey_public": [UInt8](sp),
                "signature": [UInt8](sig),
                "verifying_key": [UInt8](vk),
                "suite_id": sid
            ]
            return [UInt8](try JSONSerialization.data(withJSONObject: dict))
        }

        /// Initiate session as sender (X3DH)
        func initSenderSession(to contactId: String,
                                recipientBundle: (identityPublic: String, signedPrekeyPublic: String,
                                                  signature: String, verifyingKey: String, suiteId: String)) throws {
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
                                  senderBundle: (identityPublic: String, signedPrekeyPublic: String,
                                                 signature: String, verifyingKey: String, suiteId: String),
                                  wirePayload: Data) throws -> String {
            let bundleBytes = try bundleBytes(from: senderBundle)
            let decoded = try WirePayloadCoder.decode(wirePayload)
            let unpadded = MessagePadding.unpadCiphertext(decoded.content)

            let msgDict: [String: Any] = [
                "ephemeral_public_key": decoded.ephemeralPublicKey,
                "message_number": decoded.messageNumber,
                "content": [UInt8](unpadded)
            ]
            let msgBytes = [UInt8](try JSONSerialization.data(withJSONObject: msgDict))

            let result = try core.initReceivingSession(
                contactId: contactId,
                recipientBundle: bundleBytes,
                firstMessage: msgBytes
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
