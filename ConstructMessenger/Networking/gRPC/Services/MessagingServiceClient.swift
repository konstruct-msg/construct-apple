//
//  MessagingServiceClient.swift
//  Construct Messenger
//
//  gRPC MessagingService client — replaces MessagingAPI for message sending
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
#if canImport(UIKit)
import UIKit
#endif


final class MessagingServiceClient: Sendable {
    static let shared = MessagingServiceClient()

    private init() {}

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
        let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "send-msg-rpc") { }
        defer { UIApplication.shared.endBackgroundTask(bgTaskId) }
        #endif
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.sendMessage, fastICEFallback: true) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var sender = Shared_Proto_Core_V1_UserId()
            sender.userID = senderId

            var recipient = Shared_Proto_Core_V1_UserId()
            recipient.userID = recipientId

            var envelope = Shared_Proto_Core_V1_Envelope()
            envelope.messageID = messageId
            envelope.recipient = recipient
            envelope.conversationID = conversationId
            envelope.contentType = contentType
            envelope.encryptedPayload = encryptedPayload
            envelope.timestamp = Int64(timestamp)

            if let sealedInner = sealedInnerBytes, !sealedInner.isEmpty {
                // STEALTH: do not populate sender — build SealedSenderEnvelope
                var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
                sealedEnvelope.sealedInner = sealedInner
                envelope.sealedSender = sealedEnvelope
            } else {
                envelope.sender = sender
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

            let attemptId = UUID().uuidString.lowercased()

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = messageId
            request.attemptID = attemptId

            Log.debug("""
                📤 sendMessage RPC →
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
                Log.info("✅ sendMessage sent attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .blocked {
                status = "blocked"
                retryable = false
                errorCodeStr = "blocked"
                Log.error("🚫 Message blocked by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .rateLimit {
                status = "failed"
                retryable = true
                errorCodeStr = "rateLimit"
                Log.error("⏳ Rate limited — attemptId=\(echoedAttemptId) retryAfterMs=\(retryAfterMs) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .encryptionFailed {
                status = "failed"
                retryable = false
                errorCodeStr = "encryptionFailed"
                Log.error("🔐 Encryption rejected by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
                errorCodeStr = errorCodeRaw == .unspecified ? "" : "\(errorCodeRaw)"
                Log.error("❌ sendMessage failed — attemptId=\(echoedAttemptId) errorCode=\(errorCodeRaw) retryable=\(retryable) messageId=\(response.messageID)", category: "MessagingServiceClient")
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

    func sendEndSession(to recipientId: String, reason: String? = nil) async throws -> EndSessionResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.endSession, fastICEFallback: true) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            let messageId = UUID().uuidString

            var sender = Shared_Proto_Core_V1_UserId()
            sender.userID = SessionManager.shared.currentUserId ?? ""

            var recipient = Shared_Proto_Core_V1_UserId()
            recipient.userID = recipientId

            var envelope = Shared_Proto_Core_V1_Envelope()
            envelope.messageID = messageId
            envelope.sender = sender
            envelope.recipient = recipient
            envelope.contentType = .sessionReset
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            // Always populate encrypted_payload — server validates it is non-empty.
            envelope.encryptedPayload = Data(count: 16)

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
            // SESSION_RESET_INIT: atomic END_SESSION + new X3DH init — must be checked first
            // (has a real payload, would be mis-classified by the END_SESSION size heuristic).
            if msg.contentType == .sessionResetInit {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("⚠️ Failed to decode SESSION_RESET_INIT payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                Log.debug("🔄 SESSION_RESET_INIT pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: "SESSION_RESET_INIT",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    rawPayload: msg.encryptedPayload
                )
            }
            // END_SESSION: detect by contentType OR sentinel payload size (server may strip contentType).
            let isEndSession = msg.contentType == .sessionReset ||
                (!msg.encryptedPayload.isEmpty && msg.encryptedPayload.count < WirePayloadCoder.headerSize)
            if isEndSession {
                let detected = msg.contentType == .sessionReset ? "contentType" : "sentinel payload (\(msg.encryptedPayload.count)b)"
                Log.debug("🛑 END_SESSION pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))… via \(detected)", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: "CONTROL_MESSAGE",
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(msg.timestamp),
                    kemCiphertext: Data(),
                    kyberOtpkId: 0
                )
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session.
            // Note: PendingMessage proto does not yet carry senderDevice/conversationID;
            // those fields are only available in the live stream Envelope.
            // Leave them empty here — handleSenderSync will ACK and skip if unable to route.
            if msg.contentType == .senderSync {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("⚠️ Failed to decode SENDER_SYNC payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: "SENDER_SYNC",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    kyberOtpkId: decoded.kyberOtpkId,
                    senderDeviceId: "",
                    conversationId: ""
                )
            }
            // Unpack wire payload blob into crypto components.
            // For STEALTH messages, `sealedInnerData` is populated and `senderID` is empty.
            let sealedInner = msg.sealedInnerData
            let isSealed = !sealedInner.isEmpty
            guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                if isSealed {
                    // Sealed message payload is inside SealedInner — carry sealedInnerData
                    // for MessageRouter to decrypt and route.
                    return ChatMessage(
                        id: msg.messageID,
                        from: "",
                        to: "",
                        messageType: "DIRECT_MESSAGE",
                        ephemeralPublicKey: Data(),
                        messageNumber: 0,
                        content: Data(),
                        suiteId: 1,
                        timestamp: UInt64(msg.timestamp),
                        kemCiphertext: Data(),
                        sealedInnerData: sealedInner
                    )
                }
                Log.debug("⚠️ Failed to decode encrypted_payload for message \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                return nil
            }
            return ChatMessage(
                id: msg.messageID,
                from: msg.senderID,
                to: "",
                messageType: "DIRECT_MESSAGE",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: 1,
                timestamp: UInt64(msg.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(msg.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                senderDeviceId: "",
                conversationId: "",
                rawPayload: msg.encryptedPayload,
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPendingMessages, fastICEFallback: true) { grpcClient in
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.editMessage, fastICEFallback: true) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_EditMessageRequest()
            request.messageID = messageId
            request.conversationID = conversationId
            request.newEncryptedContent = newEncryptedContent
            request.recipientUserID = recipientUserId

            Log.debug("✏️ editMessage RPC → messageId=\(messageId.prefix(8))…", category: "MessagingServiceClient")

            let response = try await msgClient.editMessage(
                request: .init(message: request)
            )
            Log.info("✅ editMessage response: success=\(response.success) editCount=\(response.editCount)", category: "MessagingServiceClient")
            return response
        }
    }
}
