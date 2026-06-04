//
//  MessageStreamParser.swift
//  Construct Messenger
//
//  Parses raw MessageStreamResponse proto messages into typed StreamEvents.
//  Stateless — no reference to MessageStreamManager instance.
//

import Foundation

enum MessageStreamParser {
    /// Convert a raw gRPC MessageStreamResponse into a typed StreamEvent.
    /// Returns nil for response types that require no further processing (typing, ack, presence).
    static func parse(
        _ response: Shared_Proto_Services_V1_MessageStreamResponse
    ) -> StreamEvent? {
        let cursor = response.hasStreamCursor ? response.streamCursor : nil
        switch response.response {
        case .message(let envelope):
            // KEY_SYNC: server-triggered re-key signal — no encrypted payload, route directly
            if envelope.contentType == .keySync {
                Log.info("KEY_SYNC envelope from \(envelope.sender.userID.prefix(8))…", category: "MessageStream")
                return .keySyncRequest(envelope.sender.userID, cursor: cursor)
            }
            // SESSION_RESET_INIT: atomic END_SESSION + new X3DH session init in one delivery.
            // Must be checked BEFORE the END_SESSION payload-size heuristic (it has a real payload).
            if envelope.contentType == .sessionResetInit {
                guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                    Log.info("Failed to decode SESSION_RESET_INIT payload for message \(envelope.messageID)", category: "MessageStream")
                    return nil
                }
                Log.info("SESSION_RESET_INIT from \(envelope.sender.userID.prefix(8))… id=\(envelope.messageID.prefix(8))…", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "SESSION_RESET_INIT",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    rawPayload: envelope.encryptedPayload
                ), cursor: cursor)
            }
            // END_SESSION: detect by contentType OR by payload size.
            // Servers may strip contentType when relaying — fall back to payload size:
            // real WirePayload is always ≥ WirePayloadCoder.headerSize (46) bytes;
            // END_SESSION uses Data(count:16), so any non-empty payload < 46 bytes is a control sentinel.
            let isEndSession = envelope.contentType == .sessionReset ||
                (!envelope.encryptedPayload.isEmpty && envelope.encryptedPayload.count < WirePayloadCoder.headerSize)
            if isEndSession {
                let detected = envelope.contentType == .sessionReset ? "contentType" : "sentinel payload (\(envelope.encryptedPayload.count)b)"
                Log.info("END_SESSION from \(envelope.sender.userID.prefix(8))… id=\(envelope.messageID.prefix(8))… detected via \(detected)", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "CONTROL_MESSAGE",
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    kemCiphertext: Data(),
                    kyberOtpkId: 0
                ), cursor: cursor)
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session
            if envelope.contentType == .senderSync {
                guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                    Log.info("Failed to decode SENDER_SYNC payload for message \(envelope.messageID)", category: "MessageStream")
                    return nil
                }
                Log.info("SENDER_SYNC from device \(envelope.senderDevice.deviceID.prefix(8))… id=\(envelope.messageID.prefix(8))…", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "SENDER_SYNC",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    kyberOtpkId: decoded.kyberOtpkId,
                    senderDeviceId: envelope.senderDevice.deviceID,
                    conversationId: envelope.conversationID
                ), cursor: cursor)
            }
            // Unpack wire payload blob into crypto components.
            // STEALTH (sealed sender): SealedInner bytes can't be WirePayload-decoded here —
            // MessageRouter resolves the sender and extracts the real payload.
            let isSealed = envelope.hasSealedSender
            let sealedInnerBytes = isSealed ? envelope.sealedSender.sealedInner : Data()
            let senderUserId = isSealed ? "" : envelope.sender.userID

            if isSealed {
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: "",
                    to: envelope.recipient.userID,
                    messageType: "DIRECT_MESSAGE",
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    editsMessageId: envelope.editsMessageID,
                    kemCiphertext: Data(),
                    contentType: UInt8(envelope.contentType.rawValue),
                    senderDeviceId: envelope.senderDevice.deviceID,
                    conversationId: envelope.conversationID,
                    sealedInnerData: sealedInnerBytes
                ), cursor: cursor)
            }

            guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                Log.info("Failed to decode encrypted_payload for message \(envelope.messageID)", category: "MessageStream")
                return nil
            }
            let msg = ChatMessage(
                id: envelope.messageID,
                from: senderUserId,
                to: envelope.recipient.userID,
                messageType: "DIRECT_MESSAGE",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: 1,
                timestamp: UInt64(envelope.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                editsMessageId: envelope.editsMessageID,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(envelope.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                senderDeviceId: envelope.senderDevice.deviceID,
                conversationId: envelope.conversationID,
                rawPayload: envelope.encryptedPayload
            )
            PerformanceMetrics.shared.messageEnvelopeArrived(messageId: envelope.messageID)
            return .message(msg, cursor: cursor)
        case .receipt(let receipt):
            // Deliver receipt: extract confirmed message IDs and propagate
            if case .direct(let directReceipt) = receipt.receiptType,
               directReceipt.status == .delivered,
               !directReceipt.messageIds.isEmpty {
                return .deliveryReceipt(directReceipt.messageIds, cursor: cursor)
            }
            return nil
        case .typing(let indicator):
            Log.debug("Typing: \(indicator.userID) in \(indicator.conversationID)", category: "MessageStream")
            return nil
        case .ack(let ack):
            Log.debug("Message ack: \(ack.messageID)", category: "MessageStream")
            return nil
        case .error(let error):
            Log.error("Stream error: \(error.errorCode) - \(error.errorMessage)", category: "MessageStream")
            return nil
        case .presence(let update):
            Log.debug("Presence: \(update.userID)", category: "MessageStream")
            return nil
        case .heartbeatAck(let ack):
            Log.debug("Heartbeat ack: server=\(ack.serverTimestamp)", category: "MessageStream")
            Task { @MainActor in
                ConnectionStatusManager.shared.markRequestSucceeded()
            }
            return .heartbeat(cursor: cursor)
        case .none:
            return nil
        }
    }
}
