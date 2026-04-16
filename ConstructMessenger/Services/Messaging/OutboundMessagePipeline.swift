import Foundation

/// Outbound message pipeline: single place to send chunked messages, persist wire-payloads
/// for safe retries, and aggregate per-chunk server responses into a single decision.
@MainActor
final class OutboundMessagePipeline {
    static let shared = OutboundMessagePipeline()

    private init() {}

    func sendChunks(
        plan: ChunkedMessagePlan,
        baseMessageId: String,
        senderId: String,
        recipientId: String,
        conversationId: String,
        timestamp: UInt64,
        recipientIdentityKey: Data? = nil
    ) async throws -> SendMessageResponse {
        let responses = try await ChunkedMessageSender.shared.sendChunks(
            plan: plan,
            senderId: senderId,
            recipientId: recipientId,
            conversationId: conversationId,
            timestamp: timestamp,
            recipientIdentityKey: recipientIdentityKey,
            onWirePayloadEncoded: { chunkId, wire in
                OutgoingWirePayloadStore.shared.saveChunk(
                    baseMessageId: baseMessageId,
                    chunkMessageId: chunkId,
                    wirePayload: wire
                )
            }
        )

        return aggregate(responses: responses, baseMessageId: baseMessageId)
    }

    private func aggregate(responses: [SendMessageResponse], baseMessageId: String) -> SendMessageResponse {
        var status = "sent"
        var retryable = true
        var errorCode = ""
        var retryAfterMs: Int64 = 0
        for r in responses {
            let st = r.status.lowercased()
            if st == "failed" {
                status = "failed"
                retryable = retryable && r.retryable
            } else if st == "queued", status != "failed" {
                status = "queued"
                retryable = retryable && r.retryable
            } else if st == "delivered", status == "sent" {
                status = "delivered"
                retryable = retryable && r.retryable
            } else {
                retryable = retryable && r.retryable
            }
            // Propagate first non-empty error code
            if errorCode.isEmpty, !r.errorCode.isEmpty {
                errorCode = r.errorCode
            }
            // Use the longest retry-after hint from all chunks
            if r.retryAfterMs > retryAfterMs {
                retryAfterMs = r.retryAfterMs
            }
        }
        return SendMessageResponse(
            messageId: baseMessageId,
            status: status,
            retryable: retryable,
            errorCode: errorCode,
            retryAfterMs: retryAfterMs
        )
    }
}
