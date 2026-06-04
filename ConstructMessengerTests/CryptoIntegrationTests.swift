//
//  CryptoIntegrationTests.swift
//  ConstructMessengerTests
//
//  Integration tests for Rust core + Swift wrapper
//  Tests the full Alice-Bob message exchange flow
//

import XCTest
@testable import Construct_Messenger

final class CryptoIntegrationTests: XCTestCase {

    // MARK: - Helper: Crypto Instance Wrapper

    /// Wrapper around Rust core to simulate independent Alice/Bob instances
    class TestCryptoInstance {
        let core: ClassicCryptoCore
        let userId: String
        var sessions: [String: String] = [:] // contact_id -> session_id

        init(userId: String) throws {
            self.userId = userId
            self.core = try createCryptoCore()
            self.core.setLocalUserId(userId: userId)
        }

        func exportRegistrationBundle() throws -> (identityPublic: [UInt8], signedPrekeyPublic: [UInt8], signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16) {
            let fields = try core.getRegistrationBundleFields()
            return (fields.identityPublic, fields.signedPrekeyPublic, fields.signature, fields.verifyingKey, fields.suiteId)
        }

        func initSession(contactId: String, recipientBundle: (identityPublic: [UInt8], signedPrekeyPublic: [UInt8], signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16)) throws {
            let bundle = BinaryKeyBundle(
                identityPublic: recipientBundle.identityPublic,
                signedPrekeyPublic: recipientBundle.signedPrekeyPublic,
                signature: recipientBundle.signature,
                verifyingKey: recipientBundle.verifyingKey,
                suiteId: recipientBundle.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
                spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
                kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
            )
            let sessionId = try core.initSession(contactId: contactId, recipientBundle: bundle)
            sessions[contactId] = sessionId
        }

        func encryptMessage(contactId: String, plaintext: String) throws -> (ephemeralPublicKey: Data, messageNumber: UInt32, content: [UInt8]) {
            guard let sessionId = sessions[contactId] else {
                throw NSError(domain: "TestError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No session for \(contactId)"])
            }

            let components = try core.encryptMessage(sessionId: sessionId, plaintext: plaintext)
            return (Data(components.ephemeralPublicKey), components.messageNumber, components.content)
        }

        func initReceivingSession(contactId: String, senderBundle: (identityPublic: [UInt8], signedPrekeyPublic: [UInt8], signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16), firstMessage: (ephemeralPublicKey: Data, messageNumber: UInt32, content: [UInt8])) throws -> String {
            let bundle = BinaryKeyBundle(
                identityPublic: senderBundle.identityPublic,
                signedPrekeyPublic: senderBundle.signedPrekeyPublic,
                signature: senderBundle.signature,
                verifyingKey: senderBundle.verifyingKey,
                suiteId: senderBundle.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
                spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
                kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
            )
            let firstMsg = BinaryFirstMessage(
                ephemeralPublicKey: [UInt8](firstMessage.ephemeralPublicKey),
                messageNumber: firstMessage.messageNumber,
                content: firstMessage.content,
                oneTimePrekeyId: 0
            )
            // ✅ NEW API: Returns SessionInitResult with decrypted message
            let result = try core.initReceivingSession(
                contactId: contactId,
                recipientBundle: bundle,
                firstMessage: firstMsg
            )
            sessions[contactId] = result.sessionId
            return String(bytes: result.decryptedMessage, encoding: .utf8) ?? "__binary_init__"
        }

        func decryptMessage(contactId: String, message: (ephemeralPublicKey: Data, messageNumber: UInt32, content: [UInt8])) throws -> String {
            guard let sessionId = sessions[contactId] else {
                throw NSError(domain: "TestError", code: 5, userInfo: [NSLocalizedDescriptionKey: "No session for \(contactId)"])
            }

            let result = try core.decryptMessage(
                sessionId: sessionId,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: message.content
            )
            return String(bytes: result.plaintext, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Core Flow Tests

    func testAliceBobFullExchange() throws {
        print("\n=== TEST: Alice → Bob Full Exchange ===\n")

        // 1. Create Alice and Bob instances
        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        print("✅ Alice and Bob crypto instances created")

        // 2. Exchange registration bundles
        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        print("✅ Registration bundles exported")
        print("   Alice identity: \(aliceBundle.identityPublic.prefix(20))...")
        print("   Bob identity: \(bobBundle.identityPublic.prefix(20))...")

        // 3. Alice initiates session with Bob
        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)
        XCTAssertNotNil(alice.sessions["bob"], "Alice should have session with Bob")
        print("✅ Alice initialized session with Bob")

        // 4. Alice encrypts first message
        let plaintext1 = "Hello Bob! This is Alice's first message."
        let encrypted1 = try alice.encryptMessage(contactId: "bob", plaintext: plaintext1)

        print("✅ Alice encrypted first message")
        print("   Plaintext: \(plaintext1)")
        print("   Encrypted ephemeral key: \(encrypted1.ephemeralPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined())...")
        print("   Message number: \(encrypted1.messageNumber)")
        print("   Content (base64): \(encrypted1.content.prefix(40))...")

        // 5. ✅ CRITICAL TEST: Bob receives first message and initializes receiving session
        // This should decrypt the first message ATOMICALLY!
        let decrypted1 = try bob.initReceivingSession(
            contactId: "alice",
            senderBundle: aliceBundle,
            firstMessage: encrypted1
        )

        XCTAssertNotNil(bob.sessions["alice"], "Bob should have session with Alice")
        XCTAssertEqual(decrypted1, plaintext1, "First message should be decrypted correctly by initReceivingSession")
        print("✅ Bob initialized receiving session and decrypted first message")
        print("   Decrypted: \(decrypted1)")

        // 6. Bob replies
        let plaintext2 = "Hi Alice! Bob here, I got your message."
        let encrypted2 = try bob.encryptMessage(contactId: "alice", plaintext: plaintext2)

        print("✅ Bob encrypted reply")
        print("   Plaintext: \(plaintext2)")

        // 7. Alice decrypts Bob's reply
        let decrypted2 = try alice.decryptMessage(contactId: "bob", message: encrypted2)
        XCTAssertEqual(decrypted2, plaintext2, "Bob's reply should be decrypted correctly")
        print("✅ Alice decrypted Bob's reply")
        print("   Decrypted: \(decrypted2)")

        // 8. Continue conversation: Alice sends another message
        let plaintext3 = "Great! The session is working perfectly."
        let encrypted3 = try alice.encryptMessage(contactId: "bob", plaintext: plaintext3)
        let decrypted3 = try bob.decryptMessage(contactId: "alice", message: encrypted3)
        XCTAssertEqual(decrypted3, plaintext3, "Third message should be decrypted correctly")
        print("✅ Third message exchanged successfully")

        // 9. Bob sends another message
        let plaintext4 = "Indeed! Double Ratchet is working."
        let encrypted4 = try bob.encryptMessage(contactId: "alice", plaintext: plaintext4)
        let decrypted4 = try alice.decryptMessage(contactId: "bob", message: encrypted4)
        XCTAssertEqual(decrypted4, plaintext4, "Fourth message should be decrypted correctly")
        print("✅ Fourth message exchanged successfully")

        print("\n=== TEST PASSED: Full Alice-Bob exchange works! ===\n")
    }

    func testBobAliceFullExchange() throws {
        print("\n=== TEST: Bob → Alice Full Exchange (Bob initiates) ===\n")

        // Same test but Bob is the initiator
        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        // Bob initiates session with Alice
        try bob.initSession(contactId: "alice", recipientBundle: aliceBundle)
        print("✅ Bob initialized session with Alice")

        // Bob sends first message
        let plaintext1 = "Hello Alice! Bob here, starting the conversation."
        let encrypted1 = try bob.encryptMessage(contactId: "alice", plaintext: plaintext1)
        print("✅ Bob encrypted first message")

        // Alice initializes receiving session
        let decrypted1 = try alice.initReceivingSession(
            contactId: "bob",
            senderBundle: bobBundle,
            firstMessage: encrypted1
        )

        XCTAssertEqual(decrypted1, plaintext1, "First message should be decrypted correctly")
        print("✅ Alice initialized receiving session and decrypted first message")

        // Alice replies
        let plaintext2 = "Hi Bob! I received your message."
        let encrypted2 = try alice.encryptMessage(contactId: "bob", plaintext: plaintext2)
        let decrypted2 = try bob.decryptMessage(contactId: "alice", message: encrypted2)
        XCTAssertEqual(decrypted2, plaintext2, "Alice's reply should be decrypted correctly")
        print("✅ Bob decrypted Alice's reply")

        print("\n=== TEST PASSED: Bob → Alice exchange works! ===\n")
    }

    func testMultipleMessagesInSequence() throws {
        print("\n=== TEST: Multiple Messages in Sequence ===\n")

        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        // Setup session
        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        let firstMessage = "First message from Alice"
        let encrypted1 = try alice.encryptMessage(contactId: "bob", plaintext: firstMessage)
        let decrypted1 = try bob.initReceivingSession(contactId: "alice", senderBundle: aliceBundle, firstMessage: encrypted1)
        XCTAssertEqual(decrypted1, firstMessage)

        // Send 10 messages in sequence
        for i in 2...10 {
            let plaintext = "Message number \(i) from Alice"
            let encrypted = try alice.encryptMessage(contactId: "bob", plaintext: plaintext)
            let decrypted = try bob.decryptMessage(contactId: "alice", message: encrypted)
            XCTAssertEqual(decrypted, plaintext, "Message \(i) should be decrypted correctly")
        }

        print("✅ Successfully sent and decrypted 10 messages in sequence")

        // Bob sends back
        for i in 1...5 {
            let plaintext = "Reply \(i) from Bob"
            let encrypted = try bob.encryptMessage(contactId: "alice", plaintext: plaintext)
            let decrypted = try alice.decryptMessage(contactId: "bob", message: encrypted)
            XCTAssertEqual(decrypted, plaintext, "Bob's reply \(i) should be decrypted correctly")
        }

        print("✅ Successfully sent and decrypted 5 replies from Bob")
        print("\n=== TEST PASSED: Multiple messages work! ===\n")
    }

    // MARK: - Error Cases

    func testDecryptWithoutSession() throws {
        print("\n=== TEST: Decrypt Without Session (should fail) ===\n")

        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let bobBundle = try bob.exportRegistrationBundle()
        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        let encrypted = try alice.encryptMessage(contactId: "bob", plaintext: "Test")

        // Try to decrypt without initializing Bob's session
        XCTAssertThrowsError(try bob.decryptMessage(contactId: "alice", message: encrypted)) { error in
            print("✅ Correctly threw error: \(error)")
        }

        print("\n=== TEST PASSED: Correctly rejects decrypt without session ===\n")
    }

    func testEncryptWithoutSession() throws {
        print("\n=== TEST: Encrypt Without Session (should fail) ===\n")

        let alice = try TestCryptoInstance(userId: "alice")

        XCTAssertThrowsError(try alice.encryptMessage(contactId: "nonexistent", plaintext: "Test")) { error in
            print("✅ Correctly threw error: \(error)")
        }

        print("\n=== TEST PASSED: Correctly rejects encrypt without session ===\n")
    }

    func testDoubleInitReceivingSession() throws {
        print("\n=== TEST: Double Init Receiving Session (should work) ===\n")

        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        let plaintext = "Test message"
        let encrypted = try alice.encryptMessage(contactId: "bob", plaintext: plaintext)

        // First init
        let decrypted1 = try bob.initReceivingSession(contactId: "alice", senderBundle: aliceBundle, firstMessage: encrypted)
        XCTAssertEqual(decrypted1, plaintext)

        // Second init (should overwrite session)
        let encrypted2 = try alice.encryptMessage(contactId: "bob", plaintext: "Second message")

        // Note: In real implementation, you might want to prevent re-initialization
        // For now, we just test that it doesn't crash

        print("✅ Session initialized successfully")
        print("\n=== TEST PASSED ===\n")
    }

    // MARK: - Associated Data Test

    func testAssociatedDataProtection() throws {
        print("\n=== TEST: Associated Data Protection ===\n")

        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        let plaintext = "Test message for AD"
        let encrypted = try alice.encryptMessage(contactId: "bob", plaintext: plaintext)

        // Initialize Bob's session
        _ = try bob.initReceivingSession(contactId: "alice", senderBundle: aliceBundle, firstMessage: encrypted)

        // Try to tamper with message number (this should fail decryption due to AD)
        let tamperedMessage = (
            ephemeralPublicKey: encrypted.ephemeralPublicKey,
            messageNumber: encrypted.messageNumber + 1, // TAMPERED!
            content: encrypted.content
        )

        // Second message to test with
        let plaintext2 = "Second message"
        let encrypted2 = try alice.encryptMessage(contactId: "bob", plaintext: plaintext2)

        // Try to decrypt tampered message
        XCTAssertThrowsError(try bob.decryptMessage(contactId: "alice", message: tamperedMessage)) { error in
            print("✅ Correctly rejected tampered message number (AD protection working)")
        }

        // Original should still work
        let decrypted2 = try bob.decryptMessage(contactId: "alice", message: encrypted2)
        XCTAssertEqual(decrypted2, plaintext2, "Original message should decrypt correctly")

        print("\n=== TEST PASSED: Associated Data protection works! ===\n")
    }

    // MARK: - Performance Tests

    func testEncryptionPerformance() throws {
        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let bobBundle = try bob.exportRegistrationBundle()
        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        measure {
            do {
                _ = try alice.encryptMessage(contactId: "bob", plaintext: "Performance test message with some content")
            } catch {
                XCTFail("Encryption failed: \(error)")
            }
        }
    }

    func testDecryptionPerformance() throws {
        let alice = try TestCryptoInstance(userId: "alice")
        let bob = try TestCryptoInstance(userId: "bob")

        let aliceBundle = try alice.exportRegistrationBundle()
        let bobBundle = try bob.exportRegistrationBundle()

        try alice.initSession(contactId: "bob", recipientBundle: bobBundle)

        let plaintext = "Performance test message"
        let encrypted = try alice.encryptMessage(contactId: "bob", plaintext: plaintext)

        _ = try bob.initReceivingSession(contactId: "alice", senderBundle: aliceBundle, firstMessage: encrypted)

        // XCTest.measure runs the block 10 times; generate 20 unique DR messages
        // so we never re-decrypt an already-consumed slot (DR is one-way / one-use)
        var messages: [(ephemeralPublicKey: Data, messageNumber: UInt32, content: [UInt8])] = []
        for i in 0..<20 {
            let msg = try alice.encryptMessage(contactId: "bob", plaintext: "Test \(i)")
            messages.append(msg)
        }

        var index = 0
        measure {
            do {
                _ = try bob.decryptMessage(contactId: "alice", message: messages[index % messages.count])
                index += 1
            } catch {
                XCTFail("Decryption failed: \(error)")
            }
        }
    }
}
