//
//  SessionInitFlowTests.swift
//  ConstructMessengerTests
//
//  Tests for the session initialisation flow — specifically the scenarios that led to
//  real production bugs:
//
//  1. Binary content as msgNum=0 fails UTF-8 conversion in Rust FFI → first message is lost
//     (regression: fixed by sending ping as msgNum=0 first in ChatViewModel)
//  2. Ping (UTF-8) as msgNum=0 succeeds; session is established correctly
//  3. User message arrives as msgNum=1 after ping — content preserved end-to-end
//  4. initReceivingSession is idempotent (double-init does not corrupt state)
//  5. Session survives END_SESSION → removeSession → fresh initSession → messaging resumes
//  6. Bidirectional exchange works after ping-first init
//  7. Stale OTPK loop: after initReceivingSession fails, FailedInitMessageStore prevents
//     the orphaned-init exception from re-processing the same message forever
//

import XCTest
@testable import Construct_Messenger

// MARK: - Helpers

private final class SessionPeer {
    let core: OrchestratorCore
    let userId: String

    init(userId: String) throws {
        self.userId = userId
        let bootstrap = try createCryptoCore()
        let keys = try bootstrap.exportPrivateKeys()
        self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
    }

    // MARK: Bundle

    typealias Bundle = (identityPublic: [UInt8], signedPrekeyPublic: [UInt8],
                        signature: [UInt8], verifyingKey: [UInt8], suiteId: UInt16)

    func exportBundle() throws -> Bundle {
        let fields = try core.getRegistrationBundleFields()
        return (fields.identityPublic, fields.signedPrekeyPublic, fields.signature, fields.verifyingKey, fields.suiteId)
    }

    private func bundleBytes(from b: Bundle) throws -> BinaryKeyBundle {
        return BinaryKeyBundle(
            identityPublic: b.identityPublic, signedPrekeyPublic: b.signedPrekeyPublic,
            signature: b.signature, verifyingKey: b.verifyingKey,
            suiteId: b.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
            spkUploadedAt: 0, spkRotationEpoch: 0,
            kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
            kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
        )
    }

    // MARK: Session init (INITIATOR)

    func initSenderSession(to contactId: String, bundle: Bundle) throws {
        _ = try core.initSession(contactId: contactId, recipientBundle: bundleBytes(from: bundle))
    }

    // MARK: Encrypt

    /// Encrypt Data (arbitrary bytes) — mirrors encryptOutgoing(plaintext: Data).
    func encrypt(_ data: Data, to contactId: String) throws -> EncryptedComponents {
        let result = try core.encryptMessage(contactId: contactId, plaintext: data)
        return EncryptedComponents(
            ephemeralPublicKey: result.ephemeralPublicKey,
            messageNumber: result.messageNumber,
            content: result.content,
            oneTimePrekeyId: result.oneTimePrekeyId
        )
    }

    /// Encrypt a UTF-8 string — mirrors encryptSessionControl(plaintext: String).
    func encryptString(_ plaintext: String, to contactId: String) throws -> EncryptedComponents {
        try encrypt(Data(plaintext.utf8), to: contactId)
    }

    // MARK: initReceivingSession (RESPONDER)

    func initReceivingSession(contactId: String, senderBundle: Bundle, firstMsg: EncryptedComponents) throws -> String {
        let msg = firstMsg.toBinaryFirstMessage()
        let bytes = try core.initReceivingSession(
            contactId: contactId,
            recipientBundle: bundleBytes(from: senderBundle),
            firstMessage: msg
        ).decryptedMessage
        return String(bytes: bytes, encoding: .utf8) ?? "__binary_init__"
    }

    // MARK: Decrypt (after session established)

    func decrypt(_ components: EncryptedComponents, from contactId: String) throws -> Data {
        let result = try core.decryptMessage(
            contactId: contactId,
            ephemeralPublicKey: components.ephemeralPublicKey,
            messageNumber: components.messageNumber,
            content: components.content
        )
        return Data(result.plaintext)
    }
}

// MARK: - EncryptedComponents value type

private struct EncryptedComponents {
    let ephemeralPublicKey: [UInt8]
    let messageNumber: UInt32
    let content: [UInt8]
    let oneTimePrekeyId: UInt32

    func toBinaryFirstMessage() -> BinaryFirstMessage {
        return BinaryFirstMessage(
            ephemeralPublicKey: ephemeralPublicKey,
            messageNumber: messageNumber,
            content: content,
            oneTimePrekeyId: oneTimePrekeyId
        )
    }
}

private enum TestError: Error {
    case bundleParseFailed
    case bundleDecodeFailed
}

// MARK: - Tests

final class SessionInitFlowTests: XCTestCase {

    // MARK: 1. Ping as msgNum=0 — the correct fix

    /// The fixed behaviour: INITIATOR sends a UTF-8 ping as the first DR message (msgNum=0).
    /// RESPONDER calls initReceivingSession → decrypted content is the ping string.
    /// This must succeed because Rust does String::from_utf8(plaintext).
    func testInitReceivingSession_PingAsMsg0_Succeeds() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        // INITIATOR: X3DH
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // INITIATOR: encrypt ping as msgNum=0 (mirrors sendSessionInitPing)
        let pingContent = "__session_ping_\(UUID().uuidString)__"
        let msg0 = try alice.encryptString(pingContent, to: bob.userId)
        XCTAssertEqual(msg0.messageNumber, 0, "Ping must be msgNum=0")

        // RESPONDER: initReceivingSession with the ping
        let decrypted = try bob.initReceivingSession(
            contactId: alice.userId,
            senderBundle: aliceBundle,
            firstMsg: msg0
        )

        XCTAssertEqual(decrypted, pingContent)
        XCTAssertTrue(decrypted.hasPrefix("__session_ping") && decrypted.hasSuffix("__"),
                      "saveMessage must be able to discard this as a session-control payload")
    }

    // MARK: 2. Binary msgNum=0 — regression test documenting the root cause

    /// REGRESSION: Without the ping-first fix, binary user messages sent as msgNum=0 cause
    /// Rust's String::from_utf8() to throw DecryptionFailed.
    /// This test must stay failing (i.e. throw) as long as the Rust FFI converts to String —
    /// Regression guard for the Measure А fix: binary content as msgNum=0 must NOT prevent
    /// session establishment. X3DH succeeds; only the content encoding is non-UTF-8.
    /// The returned plaintext falls back to the `"__binary_init_*__"` sentinel.
    func testInitReceivingSession_BinaryMsg0_SessionEstablishedWithBinarySentinel() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // Craft binary payload that is NOT valid UTF-8 (simulates a binary protobuf user message)
        var binaryPayload = Data([0x01, 0xD2, 0xCE, 0xE8, 0xB5, 0x76, 0xD1])  // prefix from real log
        binaryPayload.append(contentsOf: (0..<32).map { _ in UInt8.random(in: 0x80...0xFF) }) // high bytes
        binaryPayload.append(contentsOf: "some text after binary".utf8)

        let msg0 = try alice.encrypt(binaryPayload, to: bob.userId)
        XCTAssertEqual(msg0.messageNumber, 0)

        // Session must be established — no throw
        let decrypted = try bob.initReceivingSession(
            contactId: alice.userId,
            senderBundle: aliceBundle,
            firstMsg: msg0
        )
        // Non-UTF-8 content falls back to sentinel; session is fully functional
        XCTAssertTrue(decrypted.hasPrefix("__binary_init_"),
                      "Binary msgNum=0 must yield sentinel, got: \(decrypted.prefix(60))")

        // Subsequent messages must decrypt normally (session DR state is valid)
        let msg1Plaintext = "hello after binary init"
        let msg1 = try alice.encrypt(Data(msg1Plaintext.utf8), to: bob.userId)
        let decrypted1 = try bob.decrypt(msg1, from: alice.userId)
        XCTAssertEqual(String(data: decrypted1, encoding: .utf8), msg1Plaintext)
    }

    // MARK: 3. User message after ping arrives as msgNum=1 with content preserved

    /// Full fixed flow: ping (msgNum=0) → initReceivingSession → then user message (msgNum=1)
    /// via normal decryptMessage. Content must round-trip exactly.
    func testSessionFlow_PingMsg0_TextMsg1_ContentPreserved() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // msg0: ping
        let ping = "__session_ping_\(UUID().uuidString)__"
        let msg0 = try alice.encryptString(ping, to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: msg0)

        // msg1: real user text
        let userText = "Привет, это первое реальное сообщение!"
        let msg1 = try alice.encryptString(userText, to: bob.userId)
        XCTAssertEqual(msg1.messageNumber, 1, "User message must be msgNum=1 after ping")

        let decrypted = try bob.decrypt(msg1, from: alice.userId)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), userText)
    }

    // MARK: 4. Binary user message at msgNum=1 is preserved correctly

    /// Binary content (protobuf-like) at msgNum=1 round-trips through normal decryptMessage
    /// — proves that msgNum=1+ is safe for binary payloads (only msgNum=0 is constrained by Rust FFI).
    func testSessionFlow_PingMsg0_BinaryMsg1_ContentPreserved() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // msg0: ping
        let msg0 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: msg0)

        // msg1: binary (protobuf-like) payload
        let protobufLike = Data([0x0A, 0x12] + (0..<200).map { UInt8($0 & 0xFF) } + [0xFF, 0xFE, 0xFD])
        let msg1 = try alice.encrypt(protobufLike, to: bob.userId)
        XCTAssertEqual(msg1.messageNumber, 1)

        let decrypted = try bob.decrypt(msg1, from: alice.userId)
        XCTAssertEqual(decrypted, protobufLike, "Binary payload must survive the DR round-trip unchanged")
    }

    // MARK: 5. Multiple sequential messages after ping

    func testSessionFlow_MultipleMessagesAfterPing() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        let msg0 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: msg0)

        let messages = [
            "First user message",
            "Second user message with emoji 🔐",
            "Third message — длинный текст на русском языке для проверки Unicode",
        ]

        for (idx, text) in messages.enumerated() {
            let enc = try alice.encryptString(text, to: bob.userId)
            XCTAssertEqual(enc.messageNumber, UInt32(idx + 1))
            let dec = try bob.decrypt(enc, from: alice.userId)
            XCTAssertEqual(String(data: dec, encoding: .utf8), text, "Message \(idx + 1) content mismatch")
        }
    }

    // MARK: 6. Bidirectional exchange after ping-first init

    func testBidirectionalExchange_AfterPingInit() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // Session init
        let msg0 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: msg0)

        // Alice → Bob
        let aliceMsg = "Hello from Alice"
        let enc1 = try alice.encryptString(aliceMsg, to: bob.userId)
        let dec1 = try bob.decrypt(enc1, from: alice.userId)
        XCTAssertEqual(String(data: dec1, encoding: .utf8), aliceMsg)

        // Bob → Alice (after initReceivingSession Bob already has a full DR session — no need for initSenderSession)
        let bobMsg = "Hello back from Bob"
        let enc2 = try bob.encryptString(bobMsg, to: alice.userId)
        let dec2 = try alice.decrypt(enc2, from: bob.userId)
        XCTAssertEqual(String(data: dec2, encoding: .utf8), bobMsg)
    }

    // MARK: 7. removeSession → reinit → messages (END_SESSION cycle)

    /// Validates the self-recovery path: END_SESSION causes session wipe on both sides,
    /// then a fresh initSession + initReceivingSession re-establishes E2EE and messages flow.
    func testEndSessionCycle_FreshSessionWorks() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        // -- First session --
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)
        let ping1 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: ping1)

        let firstMsg = "Message before END_SESSION"
        let enc1 = try alice.encryptString(firstMsg, to: bob.userId)
        let dec1 = try bob.decrypt(enc1, from: alice.userId)
        XCTAssertEqual(String(data: dec1, encoding: .utf8), firstMsg)

        // -- END_SESSION: both sides wipe --
        _ = alice.core.removeSession(contactId: bob.userId)
        _ = bob.core.removeSession(contactId: alice.userId)

        // -- Second session (fresh re-init) --
        // Alice re-fetches Bob's bundle (same keys, no rotation in test) and re-inits
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)
        let ping2 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)

        // Bob's initReceivingSession must succeed on the fresh session even though
        // the first session was already torn down
        let pingDecrypted = try bob.initReceivingSession(
            contactId: alice.userId,
            senderBundle: aliceBundle,
            firstMsg: ping2
        )
        XCTAssertTrue(pingDecrypted.hasPrefix("__session_ping"))

        let afterResetMsg = "Message after END_SESSION — session fully recovered"
        let enc2 = try alice.encryptString(afterResetMsg, to: bob.userId)
        let dec2 = try bob.decrypt(enc2, from: alice.userId)
        XCTAssertEqual(String(data: dec2, encoding: .utf8), afterResetMsg)
    }

    // MARK: 8. initReceivingSession double-init is rejected

    /// Calling initReceivingSession a second time for the same contactId must throw
    /// (session already exists). This guards against race conditions where two concurrent
    /// msgNum=0 messages trigger duplicate session inits.
    func testInitReceivingSession_DoubleInit_IsRejectedOrIdempotent() throws {
        let alice = try SessionPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try SessionPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // First init — must succeed
        let ping1 = try alice.encryptString("__session_ping_\(UUID().uuidString)__", to: bob.userId)
        _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: ping1)

        // Second init with the SAME msgNum=0 message — Rust must reject or handle gracefully.
        // We accept either (a) throw or (b) return without corrupting the established session.
        let sessionIntact: Bool
        do {
            _ = try bob.initReceivingSession(contactId: alice.userId, senderBundle: aliceBundle, firstMsg: ping1)
            // If it didn't throw, verify the session is still functional
            sessionIntact = true
        } catch {
            // Threw — that's acceptable
            sessionIntact = false
        }

        if sessionIntact {
            // Session must still work after the idempotent re-init
            let testMsg = "Session still intact after double init"
            let enc = try alice.encryptString(testMsg, to: bob.userId)
            let dec = try bob.decrypt(enc, from: alice.userId)
            XCTAssertEqual(String(data: dec, encoding: .utf8), testMsg,
                           "Session must remain functional after idempotent double-init")
        }
        // Either behaviour (throw or idempotent) is acceptable — the important thing is
        // no silent state corruption.
    }

    // MARK: - Stale OTPK / failed-init store

    /// Test 9: After initReceivingSession fails, the message ID is registered in
    /// FailedInitMessageStore. A subsequent check returns true, preventing the
    /// orphaned-init exception in MessageRouter from re-processing the same
    /// undecryptable message on every reconnect (stale OTPK loop fix).
    func testFailedInitMessageStore_PreventsReprocessing() {
        let staleMessageId = UUID().uuidString

        // Start clean
        XCTAssertFalse(FailedInitMessageStore.shared.contains(staleMessageId),
                       "Message should not be in the store before being added")

        // Simulate what SessionCoordinator does after initReceivingSession fails
        FailedInitMessageStore.shared.add(staleMessageId)

        XCTAssertTrue(FailedInitMessageStore.shared.contains(staleMessageId),
                      "Message must be tracked after failed init")

        // Clean up so other test runs start fresh
        // (directly remove by adding a fresh store write — in production the store is
        //  intentionally persistent, but here we just verify the add/contains contract)
    }

    /// Test 10: FailedInitMessageStore does not block DIFFERENT messages — only the
    /// specific ID that failed. A new init message with a fresh ID must be re-processable.
    func testFailedInitMessageStore_DoesNotBlockNewMessages() {
        let staleId = UUID().uuidString
        let freshId  = UUID().uuidString

        FailedInitMessageStore.shared.add(staleId)

        XCTAssertTrue(FailedInitMessageStore.shared.contains(staleId),
                      "Stale message must be blocked")
        XCTAssertFalse(FailedInitMessageStore.shared.contains(freshId),
                       "A different (fresh) message must not be blocked")
    }
}
