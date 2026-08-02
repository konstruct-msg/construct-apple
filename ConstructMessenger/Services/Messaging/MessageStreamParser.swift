//
//  MessageStreamParser.swift
//  Construct Messenger
//
//  Parses raw MessageStreamResponse proto messages into typed StreamEvents.
//  Stateless — no reference to MessageStreamManager instance.
//

import Foundation
import SwiftProtobuf

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
            // Identified path only — sealed deliveries carry a generic outer content_type and
            // are handled below (real type recovered post-unseal via ContentTypeRouting).
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
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    rawPayload: envelope.encryptedPayload
                ), cursor: cursor)
            }
            // END_SESSION: identified path only — contentType is the sole classifier.
            // The old "payload < headerSize" heuristic was unsound under sealed sender
            // (short control inners and empty outer payloads) and is intentionally gone.
            if envelope.contentType == .sessionReset {
                Log.info("END_SESSION from \(envelope.sender.userID.prefix(8))… id=\(envelope.messageID.prefix(8))…", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    kemCiphertext: Data(),
                    contentType: 21,
                    kyberOtpkId: 0,
                    // Preserve the raw payload so the END_SESSION handler can read a typed
                    // SessionControl reason hint (e.g. .otpkUnreproducible → 3-DH re-init).
                    // Legacy senders put a 16-byte sentinel here, which simply won't decode.
                    rawPayload: envelope.encryptedPayload
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
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 23,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    senderDeviceId: envelope.senderDevice.deviceID,
                    conversationId: envelope.conversationID
                ), cursor: cursor)
            }
            // Unpack wire payload blob into crypto components.
            // For STEALTH (sealed sender), the wire payload may be in the outer encryptedPayload
            // or inside the SealedInner. We decode the appropriate wire data so that
            // ChatMessage gets correct msgNum/ephemeral etc, and rawPayload is set for the
            // orchestrator. The sender is resolved later in MessageRouter.
            let isSealed = envelope.hasSealedSender
            let sealedInnerBytes = isSealed ? envelope.sealedSender.sealedInner : Data()
            let senderUserId = isSealed ? "" : envelope.sender.userID

            var wirePayload = envelope.encryptedPayload
            var sealedInnerPayload = Data()
            if isSealed {
                if let sealedProto = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes) {
                    sealedInnerPayload = sealedProto.encryptedPayload
                    if wirePayload.isEmpty && !sealedInnerPayload.isEmpty {
                        wirePayload = sealedInnerPayload
                    }
                }
            }

            guard let decoded = try? WirePayloadCoder.decode(wirePayload) else {
                if isSealed {
                    // Fallback for sealed control whose inner is not a WirePayload
                    // (e.g. END_SESSION 16-byte sentinel / SessionControl). Carry sealed
                    // bytes for resolveSender AND the inner payload so reason hints survive.
                    let preservedPayload = !wirePayload.isEmpty ? wirePayload : sealedInnerPayload
                    return .message(ChatMessage(
                        id: envelope.messageID,
                        from: "",
                        to: envelope.recipient.userID,
                        ephemeralPublicKey: Data(),
                        messageNumber: 0,
                        content: Data(),
                        suiteId: 1,
                        timestamp: UInt64(envelope.timestamp),
                        kemCiphertext: Data(),
                        contentType: UInt8(clamping: envelope.contentType.rawValue),
                        senderDeviceId: envelope.senderDevice.deviceID,
                        conversationId: envelope.conversationID,
                        rawPayload: preservedPayload,
                        sealedInnerData: sealedInnerBytes
                    ), cursor: cursor)
                }
                Log.info("Failed to decode encrypted_payload for message \(envelope.messageID)", category: "MessageStream")
                return nil
            }
            let msg = ChatMessage(
                id: envelope.messageID,
                from: senderUserId,
                to: envelope.recipient.userID,
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: decoded.suiteId,
                timestamp: UInt64(envelope.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(clamping: envelope.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                pqMessageEpoch: decoded.pqMessageEpoch,
                pqRatchetField: decoded.pqRatchetField,
                senderDeviceId: envelope.senderDevice.deviceID,
                conversationId: envelope.conversationID,
                rawPayload: wirePayload,
                sealedInnerData: sealedInnerBytes
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
        case .p2PHandoff(let request):
            // P2P handoff request from server — not yet handled at the stream layer.
            Log.debug("P2P handoff request: session=\(request.p2PSessionID)", category: "MessageStream")
            return nil
        case .none:
            return nil
        }
    }
}
