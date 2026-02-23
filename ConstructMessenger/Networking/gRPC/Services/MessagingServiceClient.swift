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
}
