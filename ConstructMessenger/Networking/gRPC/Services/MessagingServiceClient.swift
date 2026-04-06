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
        replyToMessageId: String? = nil
    ) async throws -> SendMessageResponse {
        // Acquire a UIBackgroundTask so iOS cannot tear down the network connection
        // while the RPC is in flight (send_message typically takes ~150ms).
        // Without this, backgrounding immediately after Send kills the connection
        // before the server response arrives → client never sees success=true → retry storm.
        #if canImport(UIKit)
        let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "send-msg-rpc") { }
        defer { UIApplication.shared.endBackgroundTask(bgTaskId) }
        #endif
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var sender = Shared_Proto_Core_V1_UserId()
            sender.userID = senderId

            var recipient = Shared_Proto_Core_V1_UserId()
            recipient.userID = recipientId

            var envelope = Shared_Proto_Core_V1_Envelope()
            envelope.messageID = messageId
            envelope.sender = sender
            envelope.recipient = recipient
            envelope.conversationID = conversationId
            envelope.contentType = contentType
            envelope.encryptedPayload = encryptedPayload
            envelope.timestamp = Int64(timestamp)

            if let replyId = replyToMessageId, !replyId.isEmpty {
                envelope.replyToMessageID = replyId
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

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = messageId

            Log.debug("""
                📤 sendMessage RPC →
                   messageId      = \(messageId)
                   senderId       = \(senderId)
                   recipientId    = \(recipientId)
                   conversationId = \(conversationId)
                   payloadBytes   = \(encryptedPayload.count)
                """, category: "MessagingServiceClient")

            let response = try await msgClient.sendMessage(
                request: .init(message: request)
            )

            Log.info("✅ sendMessage response: success=\(response.success) errorCode=\(response.error.errorCode) messageId=\(response.messageID)", category: "MessagingServiceClient")

            let status: String
            let retryable: Bool
            if response.success {
                status = "sent"
                retryable = true
            } else if response.error.errorCode == .blocked {
                status = "blocked"
                retryable = false
                Log.error("🚫 Message rejected — recipient has blocked sender (messageId=\(response.messageID))", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
            }

            return SendMessageResponse(
                messageId: response.messageID,
                status: status,
                retryable: retryable
            )
        }
    }

    // MARK: - Send End Session (replaces MessagingAPI.sendEndSession)

    func sendEndSession(to recipientId: String, reason: String? = nil) async throws -> EndSessionResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.endSession) { grpcClient in
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
        grpcClient: GRPCClient<HTTP2ClientTransport.Posix>,
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
                    content: "END_SESSION",
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
            // Unpack wire payload blob into crypto components
            guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
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
                rawPayload: msg.encryptedPayload
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

            Log.debug("✏️ editMessage RPC → messageId=\(messageId.prefix(8))…", category: "MessagingServiceClient")

            let response = try await msgClient.editMessage(
                request: .init(message: request)
            )
            Log.info("✅ editMessage response: success=\(response.success) editCount=\(response.editCount)", category: "MessagingServiceClient")
            return response
        }
    }
}
