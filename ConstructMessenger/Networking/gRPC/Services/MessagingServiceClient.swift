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

            let response = try await msgClient.sendMessage(
                request: .init(message: request)
            )

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
            envelope.encryptedPayload = Data((reason ?? "END_SESSION").utf8)

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

    struct PendingMessagesResult: Sendable {
        let messages: [ChatMessage]
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

            let chatMessages = response.messages.compactMap { msg -> ChatMessage? in
                // Unpack wire payload blob into crypto components
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.info("⚠️ Failed to decode encrypted_payload for message \(msg.messageID)", category: "MessagingServiceClient")
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
                    timestamp: UInt64(msg.timestamp)
                )
            }

            return PendingMessagesResult(
                messages: chatMessages,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore_p
            )
        }
    }
}
