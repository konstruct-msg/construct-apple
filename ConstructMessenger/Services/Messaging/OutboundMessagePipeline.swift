import Foundation

/// In-memory map from server-assigned wire message ids to the sender's local message ids.
/// On the sealed-sender path the server reassigns every message id (it must not trust a
/// client-chosen id), so server-side delivery receipts arrive with ids the sender never
/// stored. Recording the sendMessage response id lets receipt handling find the local row.
/// Best-effort: not persisted — E2E receipts (which carry the canonical E2E id) cover the
/// post-restart case.
final class ServerMessageIdMap: @unchecked Sendable {
    static let shared = ServerMessageIdMap()

    private let lock = NSLock()
    private var serverToLocal: [String: String] = [:]
    private var insertionOrder: [String] = []
    private let capacity = 512

    private init() {}

    func record(serverId: String, localId: String) {
        let server = serverId.lowercased()
        let local = localId.lowercased()
        guard !server.isEmpty, server != local else { return }
        lock.lock()
        defer { lock.unlock() }
        if serverToLocal[server] == nil {
            insertionOrder.append(server)
            if insertionOrder.count > capacity {
                serverToLocal.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        serverToLocal[server] = local
    }

    /// Returns the local id for a (possibly server-assigned) id; identity when unknown.
    func localId(for id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return serverToLocal[id.lowercased()] ?? id
    }
}

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

        // Sealed path: the server reassigns wire ids — remember them so server-side
        // delivery receipts can be matched back to the local message row.
        for response in responses where !response.messageId.isEmpty {
            ServerMessageIdMap.shared.record(serverId: response.messageId, localId: baseMessageId)
        }

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
