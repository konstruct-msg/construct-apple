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
        recipientId: String,
        ephemeralPublicKey: Data,
        messageNumber: UInt32,
        content: String,
        timestamp: UInt64,
        suiteId: UInt16
    ) async throws -> SendMessageResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var recipient = Shared_Proto_Core_V1_UserId()
            recipient.userID = recipientId

            var clientMeta = Shared_Proto_Core_V1_ClientMetadata()
            clientMeta.clientTimestamp = Int64(timestamp)

            var envelope = Shared_Proto_Core_V1_Envelope()
            envelope.recipient = recipient
            envelope.contentType = .e2EeSignal
            envelope.timestamp = Int64(timestamp)
            envelope.encryptedPayload = Data(content.utf8)
            envelope.clientMetadata = clientMeta

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = UUID().uuidString

            let response = try await msgClient.sendMessage(
                request: .init(message: request)
            )

            // Map to existing SendMessageResponse type
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

            var recipient = Shared_Proto_Core_V1_UserId()
            recipient.userID = recipientId

            var envelope = Shared_Proto_Core_V1_Envelope()
            envelope.recipient = recipient
            envelope.contentType = .sessionReset
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            if let reason {
                envelope.encryptedPayload = Data(reason.utf8)
            }

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = UUID().uuidString

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

            let chatMessages = response.messages.map { msg in
                ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    messageType: "DIRECT_MESSAGE",
                    ephemeralPublicKey: Data(base64Encoded: msg.ephemeralPublicKey) ?? Data(),
                    messageNumber: msg.messageNumber,
                    content: msg.ciphertext,
                    suiteId: UInt16(msg.suiteID),
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
