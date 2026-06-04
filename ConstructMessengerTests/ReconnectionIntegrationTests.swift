//
//  ReconnectionIntegrationTests.swift
//  ConstructMessengerTests
//
//  Rust-backed integration tests for reconnection resilience.
//  Uses real OrchestratorCore (same helper infrastructure as SessionInitFlowTests).
//
//  Covers:
//  1. Multiple END_SESSION cycles — session remains usable after each re-init
//  2. Binary msgNum=0 regression (Measure А) — session established, full exchange works
//  3. END_SESSION + re-init preserves DR message ordering (msgNum resets per session)
//  4. Concurrent init from both sides — converges via simulated tie-break to clean state
//

import XCTest
@testable import Construct_Messenger

// MARK: - Helpers (mirrors SessionInitFlowTests private types — duplicated for isolation)

private final class ReconnPeer {
    let core: OrchestratorCore
    let userId: String

    init(userId: String) throws {
        self.userId = userId
        let bootstrap = try createCryptoCore()
        let keys = try bootstrap.exportPrivateKeys()
        self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
    }

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

    func initSender(to contactId: String, bundle: Bundle) throws {
        _ = try core.initSession(contactId: contactId, recipientBundle: bundleBytes(from: bundle))
    }

    func initReceiving(contactId: String, senderBundle: Bundle, firstMsg: ReconnEncMsg) throws -> String {
        let bytes = try core.initReceivingSession(
            contactId: contactId,
            recipientBundle: bundleBytes(from: senderBundle),
            firstMessage: firstMsg.toBytes()
        ).decryptedMessage
        return String(bytes: bytes, encoding: .utf8) ?? "__binary_init__"
    }

    func encrypt(_ data: Data, to contactId: String) throws -> ReconnEncMsg {
        let r = try core.encryptMessage(contactId: contactId, plaintext: data)
        return ReconnEncMsg(ephemeralPublicKey: r.ephemeralPublicKey,
                            messageNumber: r.messageNumber,
                            content: r.content,
                            oneTimePrekeyId: r.oneTimePrekeyId)
    }

    func encryptString(_ s: String, to contactId: String) throws -> ReconnEncMsg {
        try encrypt(Data(s.utf8), to: contactId)
    }

    func decrypt(_ msg: ReconnEncMsg, from contactId: String) throws -> String {
        let r = try core.decryptMessage(contactId: contactId,
                                        ephemeralPublicKey: msg.ephemeralPublicKey,
                                        messageNumber: msg.messageNumber,
                                        content: msg.content)
        return String(bytes: r.plaintext, encoding: .utf8) ?? "<binary>"
    }

    func wipeSession(to contactId: String) {
        try? core.removeSession(contactId: contactId)
    }

    func hasSession(to contactId: String) -> Bool {
        core.hasSession(contactId: contactId)
    }
}

private struct ReconnEncMsg {
    let ephemeralPublicKey: [UInt8]
    let messageNumber: UInt32
    let content: [UInt8]
    let oneTimePrekeyId: UInt32

    func toBytes() -> BinaryFirstMessage {
        return BinaryFirstMessage(
            ephemeralPublicKey: ephemeralPublicKey,
            messageNumber: messageNumber,
            content: content,
            oneTimePrekeyId: oneTimePrekeyId
        )
    }
}

private enum ReconnTestError: Error {
    case bundleParseFailed
    case bundleDecodeFailed
}

// MARK: - Helper: one full session init cycle (ping-first pattern)

/// Sets up a full bidirectional session between `initiator` and `responder`.
/// Mirrors the production ping-first flow: INITIATOR sends "__session_ping_UUID__" as msgNum=0.
/// Returns the ping string decrypted by responder (for assertion).
@discardableResult
private func establishSession(initiator: ReconnPeer, responder: ReconnPeer) throws -> String {
    let responderBundle  = try responder.exportBundle()
    let initiatorBundle  = try initiator.exportBundle()

    try initiator.initSender(to: responder.userId, bundle: responderBundle)

    let ping = "__session_ping_\(UUID().uuidString)__"
    let msg0 = try initiator.encryptString(ping, to: responder.userId)
    XCTAssertEqual(msg0.messageNumber, 0)

    let decrypted = try responder.initReceiving(
        contactId: initiator.userId,
        senderBundle: initiatorBundle,
        firstMsg: msg0
    )
    return decrypted
}

// MARK: - Tests

final class ReconnectionIntegrationTests: XCTestCase {

    // MARK: 1. Multiple END_SESSION cycles

    /// Simulates 3 complete session tear-down/re-init cycles.
    /// After each cycle, both sides must encrypt and decrypt successfully.
    /// This guards against DR state corruption after repeated wipes.
    func testMultipleEndSessionCycles_SessionUsableAfterEach() throws {
        let alice = try ReconnPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-\(UUID().uuidString)")

        for cycle in 1...3 {
            // Establish fresh session
            try establishSession(initiator: alice, responder: bob)
            XCTAssertTrue(alice.hasSession(to: bob.userId),   "Cycle \(cycle): alice must have session")
            XCTAssertTrue(bob.hasSession(to: alice.userId),   "Cycle \(cycle): bob must have session")

            // Exchange a message to verify the session is live
            let text = "cycle-\(cycle)-message"
            let enc = try alice.encryptString(text, to: bob.userId)
            let dec = try bob.decrypt(enc, from: alice.userId)
            XCTAssertEqual(dec, text, "Cycle \(cycle): message must round-trip")

            // Simulate END_SESSION — both sides wipe (production: wipe + END_SESSION signal sent)
            alice.wipeSession(to: bob.userId)
            bob.wipeSession(to: alice.userId)

            XCTAssertFalse(alice.hasSession(to: bob.userId),  "Cycle \(cycle): alice must have no session after wipe")
            XCTAssertFalse(bob.hasSession(to: alice.userId),  "Cycle \(cycle): bob must have no session after wipe")
        }
    }

    // MARK: 2. Binary msgNum=0 regression (Measure А)

    /// Regression guard: binary (non-UTF-8) content as msgNum=0 must NOT prevent
    /// session establishment after the Measure А fix.
    /// Previously, String::from_utf8(plaintext_bytes) threw DecryptionFailed and
    /// triggered an unnecessary END_SESSION cascade.
    func testBinaryMsg0_MeasureA_SessionEstablished_FullExchangeWorks() throws {
        let alice = try ReconnPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        try alice.initSender(to: bob.userId, bundle: bobBundle)

        // Craft binary payload that is NOT valid UTF-8
        var binaryPayload = Data([0x01, 0xD2, 0xCE, 0xE8, 0xB5, 0x76, 0xD1])
        binaryPayload.append(contentsOf: (0..<32).map { _ in UInt8.random(in: 0x80...0xFF) })

        let msg0 = try alice.encrypt(binaryPayload, to: bob.userId)
        XCTAssertEqual(msg0.messageNumber, 0)

        // Must NOT throw — session must be established regardless of content encoding
        let decrypted = try bob.initReceiving(
            contactId: alice.userId,
            senderBundle: aliceBundle,
            firstMsg: msg0
        )
        XCTAssertTrue(decrypted.hasPrefix("__binary_init_") || decrypted == "__binary_init__",
                      "Non-UTF-8 msg0 must yield binary sentinel, got: \(decrypted.prefix(60))")

        // Session must be fully functional — msg1 must decrypt correctly
        let msg1Text = "hello after binary init"
        let msg1 = try alice.encryptString(msg1Text, to: bob.userId)
        XCTAssertEqual(msg1.messageNumber, 1)

        let dec1 = try bob.decrypt(msg1, from: alice.userId)
        XCTAssertEqual(dec1, msg1Text, "msg1 must decrypt correctly after binary msg0")
    }

    // MARK: 3. Message ordering preserved after END_SESSION + re-init

    /// After END_SESSION and a fresh session init, DR message numbers reset to 0.
    /// Messages in the new session must be numbered independently of the old session.
    func testEndSessionAndReinit_MessageNumberResetsToZero() throws {
        let alice = try ReconnPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-\(UUID().uuidString)")

        // Session 1: exchange 3 messages
        try establishSession(initiator: alice, responder: bob)
        for i in 1...3 {
            let enc = try alice.encryptString("session1-msg\(i)", to: bob.userId)
            _ = try bob.decrypt(enc, from: alice.userId)
        }

        // END_SESSION
        alice.wipeSession(to: bob.userId)
        bob.wipeSession(to: alice.userId)

        // Session 2: re-init — Alice is INITIATOR again
        try establishSession(initiator: alice, responder: bob)

        // First user message in new session must be msgNum=1 (msgNum=0 was the ping)
        let newMsg = try alice.encryptString("session2-first", to: bob.userId)
        XCTAssertEqual(newMsg.messageNumber, 1,
                       "In a fresh session, first user message must be msgNum=1 (ping was 0)")

        let decNewMsg = try bob.decrypt(newMsg, from: alice.userId)
        XCTAssertEqual(decNewMsg, "session2-first")
    }

    // MARK: 4. Bidirectional exchange after re-init

    /// After END_SESSION + re-init, both sides can send messages in any order.
    func testEndSessionAndReinit_BidirectionalExchangeWorks() throws {
        let alice = try ReconnPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-\(UUID().uuidString)")

        try establishSession(initiator: alice, responder: bob)
        alice.wipeSession(to: bob.userId)
        bob.wipeSession(to: alice.userId)

        try establishSession(initiator: alice, responder: bob)

        // Alice → Bob
        let a2b = try alice.encryptString("from alice", to: bob.userId)
        let dec1 = try bob.decrypt(a2b, from: alice.userId)
        XCTAssertEqual(dec1, "from alice")

        // Bob → Alice (DH ratchet)
        let b2a = try bob.encryptString("from bob", to: alice.userId)
        let dec2 = try alice.decrypt(b2a, from: bob.userId)
        XCTAssertEqual(dec2, "from bob")

        // Alice → Bob again (ratchet forward)
        let a2b2 = try alice.encryptString("alice again", to: bob.userId)
        let dec3 = try bob.decrypt(a2b2, from: alice.userId)
        XCTAssertEqual(dec3, "alice again")
    }

    // MARK: 5. Simulated tie-break: both sides init simultaneously

    /// When both sides call initSenderSession for each other simultaneously (tie-break),
    /// the losing side wipes its session and waits for the winner's ping.
    /// Simulates: Alice wins (higher deviceId), Bob wipes and accepts Alice's ping.
    func testTieBreak_LoserWipesAndAcceptsWinnerInit() throws {
        let alice = try ReconnPeer(userId: "alice-high-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-low-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        // Both sides start X3DH simultaneously (tie-break scenario)
        try alice.initSender(to: bob.userId, bundle: bobBundle)
        try bob.initSender(to: alice.userId, bundle: aliceBundle)

        // Bob loses the tie-break → wipes his session (mirrors SessionCoordinator.onTieBreakLose)
        bob.wipeSession(to: alice.userId)
        XCTAssertFalse(bob.hasSession(to: alice.userId), "Loser must have no session after wipe")

        // Alice (winner) sends the session ping as msgNum=0
        let ping = "__session_ping_\(UUID().uuidString)__"
        let msg0 = try alice.encryptString(ping, to: bob.userId)
        XCTAssertEqual(msg0.messageNumber, 0)

        // Bob accepts Alice's init as RESPONDER
        let decrypted = try bob.initReceiving(
            contactId: alice.userId,
            senderBundle: aliceBundle,
            firstMsg: msg0
        )
        XCTAssertTrue(decrypted.hasPrefix("__session_ping_"),
                      "Bob must receive Alice's ping: \(decrypted.prefix(60))")

        // Both sides can now exchange messages
        let enc = try alice.encryptString("post-tiebreak", to: bob.userId)
        let dec = try bob.decrypt(enc, from: alice.userId)
        XCTAssertEqual(dec, "post-tiebreak")

        let reply = try bob.encryptString("bob replies", to: alice.userId)
        let decReply = try alice.decrypt(reply, from: bob.userId)
        XCTAssertEqual(decReply, "bob replies")
    }

    // MARK: 6. Rapid consecutive END_SESSION cycles with message exchange each time

    func testRapidEndSessionCycles_TenRounds_NoStateCorruption() throws {
        let alice = try ReconnPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try ReconnPeer(userId: "bob-\(UUID().uuidString)")

        for round in 1...10 {
            try establishSession(initiator: alice, responder: bob)

            let sent = "round-\(round)"
            let enc = try alice.encryptString(sent, to: bob.userId)
            let dec = try bob.decrypt(enc, from: alice.userId)
            XCTAssertEqual(dec, sent, "Round \(round) message must round-trip")

            alice.wipeSession(to: bob.userId)
            bob.wipeSession(to: alice.userId)
        }
    }
}
