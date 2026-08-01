//
//  MessagingServiceClient.swift
//  Construct Messenger
//
//  gRPC MessagingService client — replaces MessagingAPI for message sending
//

import Foundation
import CoreData
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif


final class MessagingServiceClient: Sendable {
    static let shared = MessagingServiceClient()

    private init() {}

    /// Builds the outgoing message envelope.
    ///
    /// Extracted from `sendMessage` so the sealed-sender invariant is unit-testable without a live
    /// gRPC channel. **Invariant:** a sealed send (non-empty `sealedInnerBytes`) MUST NOT populate
    /// `sender`, `conversationID`, or `contentType` on the outer envelope — those are exactly the
    /// metadata sealed sender hides (the real content_type travels inside `SealedInner`). The
    /// identified fields are set ONLY on the non-sealed path. Empty sealed bytes are treated as
    /// identified (never silently drop the sender).
    static func buildEnvelope(
        messageId: String,
        recipientId: String,
        senderId: String,
        conversationId: String,
        encryptedPayload: Data,
        timestamp: UInt64,
        senderDeviceId: String?,
        recipientDeviceId: String?,
        contentType: Shared_Proto_Core_V1_ContentType,
        sealedInnerBytes: Data?
    ) -> Shared_Proto_Core_V1_Envelope {
        var recipient = Shared_Proto_Core_V1_UserId()
        recipient.userID = recipientId

        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = messageId
        envelope.recipient = recipient
        envelope.encryptedPayload = encryptedPayload
        envelope.timestamp = Int64(timestamp)

        if let sealedInner = sealedInnerBytes, !sealedInner.isEmpty {
            // STEALTH (stealth-sealed-sender-v2 Phase 3): do not populate sender, conversation_id,
            // or the real content_type on the outer envelope — the real content_type travels inside
            // SealedInner (see StealthSenderService.buildSealedInner) and is recovered by the
            // recipient after unsealing.
            var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
            sealedEnvelope.sealedInner = sealedInner
            envelope.sealedSender = sealedEnvelope
        } else {
            var sender = Shared_Proto_Core_V1_UserId()
            sender.userID = senderId
            envelope.sender = sender
            envelope.conversationID = conversationId
            envelope.contentType = contentType
        }

        if let senderDeviceId, !senderDeviceId.isEmpty {
            var senderDevice = Shared_Proto_Core_V1_DeviceId()
            senderDevice.deviceID = senderDeviceId
            envelope.senderDevice = senderDevice
        }
        if let recipientDeviceId, !recipientDeviceId.isEmpty {
            var recipientDevice = Shared_Proto_Core_V1_DeviceId()
            recipientDevice.deviceID = recipientDeviceId
            envelope.recipientDevice = recipientDevice
        }
        return envelope
    }

    // MARK: - Send Message (replaces MessagingAPI.sendMessage)

    func sendMessage(
        messageId: String,
        recipientId: String,
        senderId: String,
        conversationId: String,
        encryptedPayload: Data,
        timestamp: UInt64,
        senderDeviceId: String? = nil,
        recipientDeviceId: String? = nil,
        contentType: Shared_Proto_Core_V1_ContentType = .e2EeSignal,
        sealedInnerBytes: Data? = nil
    ) async throws -> SendMessageResponse {
        // Acquire a UIBackgroundTask so iOS cannot tear down the network connection
        // while the RPC is in flight (send_message typically takes ~150ms).
        // Without this, backgrounding immediately after Send kills the connection
        // before the server response arrives → client never sees success=true → retry storm.
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "send-msg-rpc") { } }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) } }
        #endif
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            let envelope = Self.buildEnvelope(
                messageId: messageId,
                recipientId: recipientId,
                senderId: senderId,
                conversationId: conversationId,
                encryptedPayload: encryptedPayload,
                timestamp: timestamp,
                senderDeviceId: senderDeviceId,
                recipientDeviceId: recipientDeviceId,
                contentType: contentType,
                sealedInnerBytes: sealedInnerBytes
            )

            let attemptId = UUID().uuidString.lowercased()

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = messageId
            request.attemptID = attemptId

            Log.debug("""
                   sendMessage RPC →
                   messageId      = \(messageId)
                   attemptId      = \(attemptId)
                   senderId       = \(sealedInnerBytes != nil ? "[STEALTH]" : senderId)
                   recipientId    = \(recipientId)
                   conversationId = \(conversationId)
                   payloadBytes   = \(encryptedPayload.count)
                """, category: "MessagingServiceClient")

            let response = try await msgClient.sendMessage(
                request: .init(message: request)
            )

            let errorCodeRaw = response.error.errorCode
            let retryAfterMs = response.error.hasRetryAfterMs ? response.error.retryAfterMs : 0
            let echoedAttemptId = response.hasAttemptID ? response.attemptID : attemptId

            let status: String
            let retryable: Bool
            let errorCodeStr: String
            if response.success {
                status = "sent"
                retryable = true
                errorCodeStr = ""
                Log.info("sendMessage sent attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .blocked {
                status = "blocked"
                retryable = false
                errorCodeStr = "blocked"
                Log.error("Message blocked by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .rateLimit {
                status = "failed"
                retryable = true
                errorCodeStr = "rateLimit"
                Log.error("Rate limited — attemptId=\(echoedAttemptId) retryAfterMs=\(retryAfterMs) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .encryptionFailed {
                status = "failed"
                retryable = false
                errorCodeStr = "encryptionFailed"
                Log.error("Encryption rejected by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
                errorCodeStr = errorCodeRaw == .unspecified ? "" : "\(errorCodeRaw)"
                Log.error("sendMessage failed — attemptId=\(echoedAttemptId) errorCode=\(errorCodeRaw) retryable=\(retryable) messageId=\(response.messageID)", category: "MessagingServiceClient")
            }

            return SendMessageResponse(
                messageId: response.messageID,
                status: status,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Send Sealed Message (stealth-sealed-sender-v2 Phase 2)

    /// Sends a sealed-sender message over the unauthenticated sealed channel via the
    /// new `SendSealedMessage` RPC — no outer `Envelope`, no sender/conversation_id/
    /// content_type on the wire. Gated by `FeatureFlags.sealedSenderUnauthenticatedTransport`;
    /// callers should fall back to `sendMessage(sealedInnerBytes:)` when the flag is off.
    func sendSealedMessage(sealedInner: Data) async throws -> SendMessageResponse {
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "send-sealed-msg-rpc") { } }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) } }
        #endif
        return try await GRPCChannelManager.shared.performSealedRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
            sealedEnvelope.sealedInner = sealedInner

            let attemptId = UUID().uuidString.lowercased()

            var request = Shared_Proto_Services_V1_SendSealedMessageRequest()
            request.sealedSender = sealedEnvelope
            request.attemptID = attemptId

            Log.debug("sendSealedMessage RPC → attemptId=\(attemptId) payloadBytes=\(sealedInner.count)", category: "MessagingServiceClient")

            let response = try await msgClient.sendSealedMessage(request: .init(message: request))

            let errorCodeRaw = response.error.errorCode
            let retryAfterMs = response.error.hasRetryAfterMs ? response.error.retryAfterMs : 0
            let echoedAttemptId = response.hasAttemptID ? response.attemptID : attemptId

            let status: String
            let retryable: Bool
            let errorCodeStr: String
            if response.success {
                status = "sent"
                retryable = true
                errorCodeStr = ""
                Log.info("sendSealedMessage sent attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .rateLimit {
                status = "failed"
                retryable = true
                errorCodeStr = "rateLimit"
                Log.error("sendSealedMessage rate limited — attemptId=\(echoedAttemptId) retryAfterMs=\(retryAfterMs)", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
                errorCodeStr = errorCodeRaw == .unspecified ? "" : "\(errorCodeRaw)"
                Log.error("sendSealedMessage failed — attemptId=\(echoedAttemptId) errorCode=\(errorCodeRaw) retryable=\(retryable)", category: "MessagingServiceClient")
            }

            return SendMessageResponse(
                messageId: response.messageID,
                status: status,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Send End Session (replaces MessagingAPI.sendEndSession)

    /// - Parameter resetReason: optional machine-readable recovery hint carried in the
    ///   END_SESSION payload as a typed `SessionControl{op: .end, reason}`. When set (≠
    ///   `.unspecified`), it tells the peer HOW to re-initialise — notably
    ///   `.otpkUnreproducible`, which asks the initiator to re-init WITHOUT a one-time
    ///   prekey (3-DH) instead of looping 4-DH. When `.unspecified`, the legacy 16-byte
    ///   sentinel payload is sent so pre-`reason` peers are unaffected. The serialized
    ///   SessionControl stays < WirePayloadCoder.headerSize so the receiver's payload-size
    ///   END_SESSION heuristic still fires even if the server strips content_type.
    func sendEndSession(
        to recipientId: String,
        reason: String? = nil,
        resetReason: Shared_Proto_Messaging_V1_SessionResetReason = .unspecified
    ) async throws -> EndSessionResponse {
        let myUserId = await MainActor.run { AuthSessionManager.shared.currentUserId } ?? ""
        let messageId = UUID().uuidString

        // Control payload: typed SessionControl when a reason is set, else the legacy 16-byte
        // sentinel (server validates the payload is non-empty either way). No nonce: END_SESSION
        // dedup is by message id/timestamp, and omitting it keeps the payload tiny.
        let controlPayload: Data
        if resetReason != .unspecified {
            var control = Shared_Proto_Messaging_V1_SessionControl()
            control.op = .end
            control.reason = resetReason
            controlPayload = (try? control.serializedData()).flatMap { $0.isEmpty ? nil : $0 } ?? Data(count: 16)
        } else {
            controlPayload = Data(count: 16)
        }

        // Stealth: seal END_SESSION like a message body — the real content type (.sessionReset)
        // rides inside SealedInner and is recovered on receive, so the outer envelope leaks no
        // sender. Sealing is X25519 cert-based, independent of the (possibly broken) DR session, so
        // it works during teardown. Fail-closed under stealth-on: never emit an identified
        // END_SESSION (decisions/sealed-sender-session-control-channel.md). If we can't seal, the
        // peer recovers via its own decrypt-fail path — anonymity over an eager teardown signal.
        func resolveRecipientIK() async -> Data? {
            await MainActor.run {
                StealthSenderService.recipientIdentityKey(
                    recipientId: recipientId,
                    context: PersistenceController.shared.container.viewContext
                )
            }
        }
        var sealedInner: Data? = nil
        if await StealthPolicy.shared.shouldUseSealedSender() {
            guard let recipientIK = await resolveRecipientIK() else {
                throw StealthDowngradeBlocked(reason: "no recipient identity key for END_SESSION → \(recipientId.prefix(8))…")
            }
            sealedInner = try await StealthSenderService.buildSealedInner(
                recipientUserId: recipientId,
                recipientIdentityKey: recipientIK,
                encryptedPayload: controlPayload,
                contentType: .sessionReset
            )
        }

        let sendOnce: (Data?) async throws -> EndSessionResponse = { inner in
            try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.endSession) { grpcClient in
                let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

                let envelope = Self.buildEnvelope(
                    messageId: messageId,
                    recipientId: recipientId,
                    senderId: myUserId,
                    conversationId: ConversationId.direct(myUserId: myUserId, theirUserId: recipientId),
                    encryptedPayload: controlPayload,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    senderDeviceId: nil,
                    recipientDeviceId: nil,
                    contentType: .sessionReset,
                    sealedInnerBytes: inner
                )

                var request = Shared_Proto_Services_V1_SendMessageRequest()
                request.message = envelope
                request.idempotencyKey = messageId

                let response = try await msgClient.sendMessage(
                    request: .init(message: request)
                )

                return EndSessionResponse(
                    status: response.success ? "ok" : "failed",
                    messageId: response.messageID,
                    type: "END_SESSION"
                )
            }
        }

        // Sealed path gets the same one-shot Privacy-Pass enforce recovery as message bodies
        // (rebuild = fresh token + delivery tag around the same control payload).
        if let sealedInner {
            return try await StealthSendRecovery.sendSealed(sealedInner, rebuild: {
                guard let ik = await resolveRecipientIK() else { return nil }
                return try await StealthSenderService.buildSealedInner(
                    recipientUserId: recipientId,
                    recipientIdentityKey: ik,
                    encryptedPayload: controlPayload,
                    contentType: .sessionReset
                )
            }, send: sendOnce)
        }
        return try await sendOnce(nil)
    }

    // MARK: - Get Pending Messages (for background fetch)

    struct FailedMessage: Sendable {
        let id: String
        let senderId: String
    }

    struct PendingMessagesResult: Sendable {
        let messages: [ChatMessage]
        /// Messages that arrived but could not be decoded (e.g. lost session key).
        /// The client should ACK these as `.failed` so the server removes them from the pending queue.
        let failedMessages: [FailedMessage]
        let nextCursor: String
        let hasMore: Bool
    }

    static func getPendingMessagesPage(
        grpcClient: GRPCClient<HTTP2ClientTransport.TransportServices>,
        sinceCursor: String? = nil,
        limit: Int32 = 50
    ) async throws -> PendingMessagesResult {
        let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

        var request = Shared_Proto_Services_V1_GetPendingMessagesRequest()
        if let sinceCursor, !sinceCursor.isEmpty {
            request.sinceCursor = sinceCursor
        }
        request.limit = limit

        let response = try await msgClient.getPendingMessages(
            request: .init(message: request)
        )

        var failed: [FailedMessage] = []
        let chatMessages = response.messages.compactMap { msg -> ChatMessage? in
            // SESSION_RESET_INIT: identified path — sealed deliveries use the generic path below.
            if msg.contentType == .sessionResetInit {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("Failed to decode SESSION_RESET_INIT payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                Log.debug("SESSION_RESET_INIT pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: .sessionResetInit,
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    rawPayload: msg.encryptedPayload
                )
            }
            // END_SESSION: contentType is the sole classifier (size heuristic removed).
            if msg.contentType == .sessionReset {
                Log.debug("END_SESSION pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: .endSession,
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(msg.timestamp),
                    kemCiphertext: Data(),
                    contentType: 21,
                    kyberOtpkId: 0,
                    rawPayload: msg.encryptedPayload
                )
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session.
            // Note: PendingMessage proto does not yet carry senderDevice/conversationID;
            // those fields are only available in the live stream Envelope.
            // Leave them empty here — handleSenderSync will ACK and skip if unable to route.
            if msg.contentType == .senderSync {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("Failed to decode SENDER_SYNC payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: .senderSync,
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 23,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    senderDeviceId: "",
                    conversationId: ""
                )
            }
            // Unpack wire payload blob into crypto components.
            // For STEALTH messages, `sealedInnerData` is populated and `senderID` is empty.
            let sealedInner = msg.sealedInnerData
            let isSealed = !sealedInner.isEmpty
            var wirePayload = msg.encryptedPayload
            var sealedInnerPayload = Data()
            if isSealed {
                if let sealedProto = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInner) {
                    sealedInnerPayload = sealedProto.encryptedPayload
                    if wirePayload.isEmpty && !sealedInnerPayload.isEmpty {
                        wirePayload = sealedInnerPayload
                    }
                }
            }
            guard let decoded = try? WirePayloadCoder.decode(wirePayload) else {
                if isSealed {
                    // Fallback for sealed control whose inner is not a WirePayload.
                    // Preserve rawPayload so SessionControl.reason survives unseal.
                    let preservedPayload = !wirePayload.isEmpty ? wirePayload : sealedInnerPayload
                    return ChatMessage(
                        id: msg.messageID,
                        from: "",
                        to: "",
                        messageType: .direct,
                        ephemeralPublicKey: Data(),
                        messageNumber: 0,
                        content: Data(),
                        suiteId: 1,
                        timestamp: UInt64(msg.timestamp),
                        kemCiphertext: Data(),
                        contentType: UInt8(clamping: msg.contentType.rawValue),
                        rawPayload: preservedPayload,
                        sealedInnerData: sealedInner
                    )
                }
                Log.debug("Failed to decode encrypted_payload for message \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                return nil
            }
            return ChatMessage(
                id: msg.messageID,
                from: isSealed ? "" : msg.senderID,
                to: "",
                messageType: .direct,
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: decoded.suiteId,
                timestamp: UInt64(msg.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(clamping: msg.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                pqMessageEpoch: decoded.pqMessageEpoch,
                pqRatchetField: decoded.pqRatchetField,
                senderDeviceId: "",
                conversationId: "",
                rawPayload: wirePayload,
                sealedInnerData: sealedInner
            )
        }

        return PendingMessagesResult(
            messages: chatMessages,
            failedMessages: failed,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore_p
        )
    }

    func getPendingMessages(sinceCursor: String? = nil, limit: Int32 = 50) async throws -> PendingMessagesResult {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPendingMessages) { grpcClient in
            try await Self.getPendingMessagesPage(grpcClient: grpcClient, sinceCursor: sinceCursor, limit: limit)
        }
    }

    // MARK: - Edit Message

    func editMessage(
        messageId: String,
        conversationId: String,
        newEncryptedContent: Data,
        recipientUserId: String
    ) async throws -> Shared_Proto_Services_V1_EditMessageResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.editMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_EditMessageRequest()
            request.messageID = messageId
            request.conversationID = conversationId
            request.newEncryptedContent = newEncryptedContent
            request.recipientUserID = recipientUserId

            Log.debug("editMessage RPC → messageId=\(messageId.prefix(8))…", category: "MessagingServiceClient")

            let response = try await msgClient.editMessage(
                request: .init(message: request)
            )
            Log.info("editMessage response: success=\(response.success) editCount=\(response.editCount)", category: "MessagingServiceClient")
            return response
        }
    }
}
