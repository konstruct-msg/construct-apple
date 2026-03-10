//
//  MessagingServiceClient.swift
//  Construct Messenger
//
//  gRPC MessagingService client — replaces MessagingAPI for message sending
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


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
        timestamp: UInt64
    ) async throws -> SendMessageResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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
            envelope.contentType = .e2EeSignal
            envelope.encryptedPayload = encryptedPayload
            envelope.timestamp = Int64(timestamp)

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

            Log.info("✅ sendMessage response: success=\(response.success) messageId=\(response.messageID)", category: "MessagingServiceClient")

            return SendMessageResponse(
                messageId: response.messageID,
                status: response.success ? "sent" : "failed"
            )
        }
    }

    // MARK: - Send End Session (replaces MessagingAPI.sendEndSession)

    func sendEndSession(to recipientId: String, reason: String? = nil) async throws -> EndSessionResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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

    func getPendingMessages(sinceCursor: String? = nil, limit: Int32 = 50) async throws -> PendingMessagesResult {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    kyberOtpkId: decoded.kyberOtpkId
                )
            }

            return PendingMessagesResult(
                messages: chatMessages,
                failedMessages: failed,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore_p
            )
        }
    }

    // MARK: - Edit Message

    func editMessage(
        messageId: String,
        conversationId: String,
        newEncryptedContent: Data,
        recipientUserId: String
    ) async throws -> Shared_Proto_Services_V1_EditMessageResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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
