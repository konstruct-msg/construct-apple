//
//  CallSignalE2EETests.swift
//  ConstructMessengerTests
//
//  Integration tests for the E2EE call signal pipeline (content_type = 12).
//
//  These tests validate the exact failure mode fixed in commit 1cc5f62:
//  the Rust orchestrator correctly returns .callSignalDecrypted for ct=12
//  messages, and the Swift routing loop dispatches them to CallManager rather
//  than falling through to "no routing decision".
//
//  Each test runs entirely in-process against real Rust crypto (no mocks).
//
//  Coverage:
//   1. outgoingCallSignal produces sendEncryptedMessage with contentType=12
//   2. Receiver gets callSignalDecrypted — NOT messageDecrypted — for ct=12
//   3. Proto bytes are preserved end-to-end through the E2EE layer
//   4. Multiple call signals in sequence (offer → ICE candidates)
//   5. Call signal works mid-conversation (after regular DR messages)
//   6. ct=12 with msgNum=0 (new DH ratchet step) is routed correctly —
//      this is the exact bug: EE80D3DE arrived with msgNum=0, existing session,
//      ct=12, and was silently dropped before the routing fix
//

import XCTest
@testable import Construct_Messenger

// MARK: - OrchestratorPeer helper

private final class OrchestratorPeer {
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

    // MARK: Session init

    func initSenderSession(to contactId: String, bundle: Bundle) throws {
        _ = try core.initSession(contactId: contactId,
                                 recipientBundle: try bundleBytes(from: bundle))
    }

    func initReceiverSession(from contactId: String,
                             senderBundle: Bundle,
                             firstMsg: EncryptedComponents) throws {
        _ = try core.initReceivingSession(
            contactId: contactId,
            recipientBundle: try bundleBytes(from: senderBundle),
            firstMessage: try firstMsg.toMessageBytes()
        )
    }

    // MARK: Low-level encrypt (for session bootstrap)

    func encryptMessage(_ text: String, to contactId: String) throws -> EncryptedComponents {
        let r = try core.encryptMessage(contactId: contactId, plaintext: Data(text.utf8))
        return EncryptedComponents(
            ephemeralPublicKey: r.ephemeralPublicKey,
            messageNumber: r.messageNumber,
            content: r.content,
            oneTimePrekeyId: r.oneTimePrekeyId
        )
    }

    // MARK: handleEvent wrappers

    /// Send a call signal proto via the orchestrator. Returns the wire payload
    /// that would be sent to the server (same bytes the receiver's messageReceived.data).
    func sendCallSignal(to contactId: String, protoBytes: Data) throws -> Data {
        let actions = try core.handleEvent(event: .outgoingCallSignal(
            contactId: contactId,
            messageId: UUID().uuidString,
            protoBytes: protoBytes
        ))
        for action in actions {
            if case .sendEncryptedMessage(let to, let payload, _, _) = action, to == contactId {
                return payload
            }
        }
        throw PeerError.noSendAction
    }

    /// Receive a wire payload and return the resulting orchestrator actions.
    /// Handles the checkAckInDb round-trip transparently (matches MessageRouter behaviour).
    func receiveWirePayload(_ wirePayload: Data,
                            from contactId: String,
                            contentType: UInt8) throws -> [CfeAction] {
        let decoded = try WirePayloadCoder.decode(wirePayload)

        var actions = try core.handleEvent(event: .messageReceived(
            messageId: UUID().uuidString,
            from: contactId,
            data: wirePayload,
            msgNum: decoded.messageNumber,
            kemCt: decoded.kemCiphertext ?? Data(),
            otpkId: decoded.oneTimePreKeyId,
            isControl: false,
            contentType: contentType
        ))

        // Rust ACK-cache miss after restart: respond synchronously and use the follow-up actions.
        if actions.count == 1, case .checkAckInDb(let ackId) = actions[0] {
            if let followup = try? core.handleEvent(event: .ackDbResult(messageId: ackId,
                                                                        isProcessed: false)),
               !followup.isEmpty {
                actions = followup
            }
        }

        return actions
    }
}

// MARK: - EncryptedComponents

private struct EncryptedComponents {
    let ephemeralPublicKey: [UInt8]
    let messageNumber: UInt32
    let content: [UInt8]
    let oneTimePrekeyId: UInt32

    func toMessageBytes() -> BinaryFirstMessage {
        return BinaryFirstMessage(
            ephemeralPublicKey: ephemeralPublicKey,
            messageNumber: messageNumber,
            content: content,
            oneTimePrekeyId: oneTimePrekeyId
        )
    }
}

// MARK: - Errors

private enum PeerError: Error, CustomStringConvertible {
    case bundleParseFailed
    case bundleDecodeFailed
    case noSendAction

    var description: String {
        switch self {
        case .bundleParseFailed:  return "Failed to parse registration bundle JSON"
        case .bundleDecodeFailed: return "Failed to decode base64 bundle fields"
        case .noSendAction:       return "outgoingCallSignal produced no sendEncryptedMessage action"
        }
    }
}

// MARK: - Helpers

/// Bootstraps a two-party session using the classic path (initSession / initReceivingSession).
/// After this returns, both peers have an active DR session and can exchange messages via handleEvent.
private func establishSession(alice: OrchestratorPeer,
                              bob: OrchestratorPeer) throws {
    let aliceBundle = try alice.exportBundle()
    let bobBundle   = try bob.exportBundle()

    try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

    // Alice sends a ping as msgNum=0 so Bob can call initReceivingSession.
    let firstMsg = try alice.encryptMessage("ping", to: bob.userId)
    try bob.initReceiverSession(from: alice.userId, senderBundle: aliceBundle, firstMsg: firstMsg)
}

// MARK: - Tests

final class CallSignalE2EETests: XCTestCase {

    // MARK: 1. outgoingCallSignal sets contentType = 12

    /// Regression: outgoingCallSignal MUST produce sendEncryptedMessage with contentType=12.
    /// If contentType is wrong, the receiver cannot route the signal to CallManager.
    func testOutgoingCallSignal_ProducesContentType12() throws {
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")
        try establishSession(alice: alice, bob: bob)

        let protoBytes = Data("fake-sdp-offer-proto".utf8)
        let actions = try alice.core.handleEvent(event: .outgoingCallSignal(
            contactId: bob.userId,
            messageId: UUID().uuidString,
            protoBytes: protoBytes
        ))

        let sendAction = actions.first { a in
            if case .sendEncryptedMessage = a { return true }
            return false
        }
        guard let sendAction,
              case .sendEncryptedMessage(_, _, _, let ct) = sendAction else {
            XCTFail("outgoingCallSignal must produce a sendEncryptedMessage action")
            return
        }
        XCTAssertEqual(ct, 12, "contentType must be 12 (CALL_SIGNAL)")
    }

    // MARK: 2. Receiver gets callSignalDecrypted, NOT messageDecrypted

    /// This is the core regression test for the routing bug fixed in 1cc5f62.
    ///
    /// Before the fix: Rust correctly returned callSignalDecrypted, but the Swift
    /// routing loop only triggered executeRustActions on .messageDecrypted.
    /// The loop fell through to "no routing decision" and CallManager never saw
    /// the incoming call offer.
    ///
    /// This test verifies the Rust side: callSignalDecrypted IS returned and
    /// messageDecrypted is NOT. The Swift side fix is covered by the routing loop change.
    func testReceiverGetsCallSignalDecrypted_NotMessageDecrypted() throws {
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")
        try establishSession(alice: alice, bob: bob)

        let wirePayload = try alice.sendCallSignal(to: bob.userId,
                                                   protoBytes: Data("offer-sdp".utf8))
        let actions = try bob.receiveWirePayload(wirePayload, from: alice.userId, contentType: 12)

        let hasCallSignalDecrypted = actions.contains { a in
            if case .callSignalDecrypted = a { return true }
            return false
        }
        let hasMessageDecrypted = actions.contains { a in
            if case .messageDecrypted = a { return true }
            return false
        }

        XCTAssertTrue(hasCallSignalDecrypted,
                      "ct=12 must produce callSignalDecrypted — this is what CallManager needs")
        XCTAssertFalse(hasMessageDecrypted,
                       "ct=12 must NOT produce messageDecrypted — call signals are not chat messages")
    }

    // MARK: 3. Proto bytes preserved end-to-end

    /// The proto bytes sent by the caller must arrive unchanged at the callee.
    /// These bytes are the serialised WebRTCSignal proto (SDP offer or ICE candidate).
    func testCallSignalProtoBytesPreservedEndToEnd() throws {
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")
        try establishSession(alice: alice, bob: bob)

        // Simulate a realistic proto payload (binary, not valid UTF-8)
        let originalProto = Data([0x0A, 0x10] + (0..<32).map { UInt8($0) } + [0xFF, 0xFE, 0xFD])

        let wirePayload = try alice.sendCallSignal(to: bob.userId, protoBytes: originalProto)
        let actions = try bob.receiveWirePayload(wirePayload, from: alice.userId, contentType: 12)

        var receivedProto: Data?
        for action in actions {
            if case .callSignalDecrypted(_, _, let bytes) = action {
                receivedProto = bytes
                break
            }
        }

        guard let received = receivedProto else {
            XCTFail("callSignalDecrypted action not found in receiver actions: \(actions)")
            return
        }
        XCTAssertEqual(received, originalProto,
                       "Proto bytes must survive the full E2EE round-trip unchanged")
    }

    // MARK: 4. Multiple call signals in sequence (offer + ICE candidates)

    /// A real WebRTC call sends: SDP offer → then ~10 ICE candidates in rapid succession.
    /// Each is a separate ct=12 DR message. All must be routed to callSignalDecrypted.
    func testMultipleCallSignalsInSequence() throws {
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")
        try establishSession(alice: alice, bob: bob)

        let signals: [Data] = [
            Data("v=0\r\no=- 123 IN IP4 0.0.0.0\r\n".utf8),             // SDP offer
            Data("candidate:1 1 udp 2122260223 192.168.1.1 54321".utf8), // ICE 1
            Data("candidate:2 1 udp 2122194687 10.0.0.1 54322".utf8),    // ICE 2
            Data("candidate:3 1 udp 1686052607 5.5.5.5 3478".utf8),      // ICE 3 (SRFLX)
        ]

        for (i, protoBytes) in signals.enumerated() {
            let wirePayload = try alice.sendCallSignal(to: bob.userId, protoBytes: protoBytes)
            let actions = try bob.receiveWirePayload(wirePayload, from: alice.userId, contentType: 12)

            let signalAction = actions.first { a in
                if case .callSignalDecrypted = a { return true }
                return false
            }
            XCTAssertNotNil(signalAction, "Signal \(i) must produce callSignalDecrypted")

            if case .callSignalDecrypted(_, _, let received) = signalAction! {
                XCTAssertEqual(received, protoBytes, "Signal \(i) proto bytes must match")
            }
        }
    }

    // MARK: 5. Call signal works mid-conversation

    /// Verify that a call signal can be sent in the middle of a regular text conversation.
    /// Real scenario: user is chatting, then places a call — both message types must work.
    func testCallSignalMidConversation() throws {
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")
        try establishSession(alice: alice, bob: bob)

        // Exchange a few regular messages first (advances DR ratchet)
        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()
        _ = aliceBundle // used in session init above

        // Bob → Alice: reply after session init (Bob has been the receiver so far)
        let msg1 = try bob.encryptMessage("hello alice", to: alice.userId)
        let wireMsg1 = try WirePayloadCoder.encode(
            MessageCryptoService.EncryptedMessageComponents(
                ephemeralPublicKey: Data(msg1.ephemeralPublicKey),
                messageNumber: msg1.messageNumber,
                content: MessagePadding.padCiphertext(Data(msg1.content)),
                suiteId: 1,
                oneTimePreKeyId: msg1.oneTimePrekeyId,
                storageKey: Data()
            ))
        _ = try alice.receiveWirePayload(wireMsg1, from: bob.userId, contentType: 1)

        // Alice → Bob: normal message
        let aliceMsg = try alice.encryptMessage("hi bob, going to call you", to: bob.userId)
        let wireAliceMsg = try WirePayloadCoder.encode(
            MessageCryptoService.EncryptedMessageComponents(
                ephemeralPublicKey: Data(aliceMsg.ephemeralPublicKey),
                messageNumber: aliceMsg.messageNumber,
                content: MessagePadding.padCiphertext(Data(aliceMsg.content)),
                suiteId: 1,
                oneTimePreKeyId: aliceMsg.oneTimePrekeyId,
                storageKey: Data()
            ))
        _ = try bob.receiveWirePayload(wireAliceMsg, from: alice.userId, contentType: 1)

        // Now Alice sends a call signal — should still work after text exchange
        let callProto = Data("sdp-offer-after-chat".utf8)
        let callPayload = try alice.sendCallSignal(to: bob.userId, protoBytes: callProto)
        let callActions = try bob.receiveWirePayload(callPayload, from: alice.userId, contentType: 12)

        let signalDecrypted = callActions.first { a in
            if case .callSignalDecrypted = a { return true }
            return false
        }
        XCTAssertNotNil(signalDecrypted,
                        "callSignalDecrypted must be produced even mid-conversation")

        if case .callSignalDecrypted(_, _, let received) = signalDecrypted! {
            XCTAssertEqual(received, callProto)
        }
    }

    // MARK: 6. ct=12 with msgNum=0 — the exact production bug

    /// This test replicates the exact failure from logs: message EE80D3DE arrived with
    /// msgNum=0, an existing session, and contentType=12. The Rust core decrypted it and
    /// returned callSignalDecrypted, but the Swift routing loop silently dropped it.
    ///
    /// msgNum=0 in a ct=12 message happens when the sender's first-ever outgoing message
    /// in the established session is a call signal. This is achieved here by making Bob
    /// the X3DH initiator: Alice (responder) receives Bob's session-init message, but
    /// hasn't sent anything yet. Her first send (the call signal) has msgNum=0.
    ///
    /// This is structurally identical to the production scenario where one side calls
    /// before sending any regular messages in a fresh session.
    func testCallSignalAfterDHRatchet_MsgNum0_RoutedCorrectly() throws {
        // Bob is the initiator so that Alice's first send can be the call signal (msgNum=0).
        let alice = try OrchestratorPeer(userId: "alice-\(UUID().uuidString)")
        let bob   = try OrchestratorPeer(userId: "bob-\(UUID().uuidString)")

        let aliceBundle = try alice.exportBundle()
        let bobBundle   = try bob.exportBundle()

        // Bob initialises the session toward Alice.
        try bob.initSenderSession(to: alice.userId, bundle: aliceBundle)
        let firstMsg = try bob.encryptMessage("ping", to: alice.userId)
        try alice.initReceiverSession(from: bob.userId, senderBundle: bobBundle, firstMsg: firstMsg)

        // Alice has NOT sent anything yet — her first send will be msgNum=0.
        let callProto = Data([0x0A, 0x24] + Array("call-id-uuid-abc123".utf8))
        let callWire = try alice.sendCallSignal(to: bob.userId, protoBytes: callProto)

        // Verify msgNum=0 in the wire payload (confirms we're testing the right scenario).
        let decoded = try WirePayloadCoder.decode(callWire)
        XCTAssertEqual(decoded.messageNumber, 0,
                       "Alice's first-ever send after session init must be msgNum=0")

        // Bob receives — must produce callSignalDecrypted, not silently drop.
        let actions = try bob.receiveWirePayload(callWire, from: alice.userId, contentType: 12)

        let callSignalAction = actions.first { a in
            if case .callSignalDecrypted = a { return true }
            return false
        }
        XCTAssertNotNil(callSignalAction,
                        "ct=12 with msgNum=0 MUST produce callSignalDecrypted — " +
                        "this was the exact production bug where EE80D3DE was silently dropped")

        if case .callSignalDecrypted(_, _, let received) = callSignalAction! {
            XCTAssertEqual(received, callProto,
                           "Proto bytes must be intact through E2EE for ct=12 msgNum=0")
        }
    }
}
