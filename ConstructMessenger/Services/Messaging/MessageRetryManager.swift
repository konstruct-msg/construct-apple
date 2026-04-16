import Foundation
import CoreData
import os.log
import GRPCCore

/// Manages message retry logic for failed and queued messages
@MainActor
class MessageRetryManager {

    static let shared = MessageRetryManager()

    private let messageQueueManager = MessageQueueManager.shared
    
    // MARK: - Single Message Retry
    
    /// Retry sending a failed or queued message
    /// - Parameters:
    ///   - message: Message to retry
    ///   - recipientId: Recipient user ID
    ///   - context: Core Data context
    ///   - onError: Callback for error messages
    func retryMessage(
        _ message: Message,
        recipientId: String,
        context: NSManagedObjectContext,
        onError: @escaping (String) -> Void
    ) {
        // ✅ Retry for failed or queued messages
        guard message.canRetry || message.deliveryStatus == .queued else {
            Log.info("Message cannot be retried", category: "MessageRetryManager")
            return
        }

        // Ensure decrypted content exists before proceeding
        guard message.decryptedContent != nil else {
            Log.error("Cannot retry - no decrypted content", category: "MessageRetryManager")
            return
        }

        // ✅ Increment retry count
        message.retryCount += 1
        context.saveAndLog()

        Log.info("🔄 Retrying message \(message.id.prefix(8))... (attempt \(message.retryCount))", category: "MessageRetryManager")

        // ✅ Update existing message status instead of creating new one
        message.deliveryStatus = .sending
        context.saveAndLog()

        let capturedMessageId = message.id
        let capturedSenderId = message.fromUserId
        let capturedTimestamp = UInt64(message.safeTimestamp.timeIntervalSince1970)

        // Prefer re-sending the exact same encrypted payload bytes.
        if let chunks = OutgoingWirePayloadStore.shared.loadChunks(baseMessageId: capturedMessageId) {
            Task {
                do {
                    var finalStatus: DeliveryStatus = .sent
                    var maxRetryAfterMs: Int64 = 0
                    var finalErrorCode: String = ""
                    for (chunkId, wirePayload) in chunks {
                        let response = try await MessagingServiceClient.shared.sendMessage(
                            messageId: chunkId,
                            recipientId: recipientId,
                            senderId: capturedSenderId,
                            conversationId: ConversationId.direct(myUserId: capturedSenderId, theirUserId: recipientId),
                            encryptedPayload: wirePayload,
                            timestamp: capturedTimestamp
                        )
                        if finalErrorCode.isEmpty, !response.errorCode.isEmpty {
                            finalErrorCode = response.errorCode
                        }
                        if response.retryAfterMs > maxRetryAfterMs {
                            maxRetryAfterMs = response.retryAfterMs
                        }
                        switch response.status.lowercased() {
                        case "failed":
                            finalStatus = response.retryable ? .queued : .failed
                        case "queued":
                            if finalStatus != .failed { finalStatus = .queued }
                        default:
                            break
                        }
                        if finalStatus == .failed { break }
                    }
                    await MainActor.run {
                        let fetchRequest = Message.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                        fetchRequest.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fetchRequest).first else { return }
                        liveMsg.deliveryStatus = finalStatus
                        context.saveAndLog()
                        if finalStatus == .sent || finalStatus == .delivered {
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: capturedMessageId)
                        }
                        let ecStr = finalErrorCode.isEmpty ? "" : " errorCode=\(finalErrorCode)"
                        let raStr = maxRetryAfterMs > 0 ? " retryAfterMs=\(maxRetryAfterMs)" : ""
                        Log.info("✅ Message retry completed: \(capturedMessageId) status=\(finalStatus)\(ecStr)\(raStr)", category: "MessageRetryManager")
                        if finalStatus == .queued, maxRetryAfterMs > 0 {
                            Log.info("⏳ Rate-limited retry — will reschedule in \(maxRetryAfterMs)ms for \(capturedMessageId.prefix(8))", category: "MessageRetryManager")
                        }
                    }
                } catch {
                    await MainActor.run {
                        let fetchRequest = Message.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                        fetchRequest.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fetchRequest).first else { return }
                        let code = (error as? RPCError).map { String(describing: $0.code).lowercased() } ?? ""
                        let isRetryableTransport = code == "deadlineexceeded" || code == "unavailable" || code == "cancelled"
                        liveMsg.deliveryStatus = isRetryableTransport ? .queued : .failed
                        context.saveAndLog()
                        if isRetryableTransport {
                            Log.info("⏸️ Retry transport failure — queued \(capturedMessageId.prefix(8))… for later", category: "MessageRetryManager")
                        } else {
                            Log.error("❌ Message retry failed: \(error.localizedDescription)", category: "MessageRetryManager")
                            onError("Failed to send message: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return
        }

        // Wire payload not found — either it predates OutgoingWirePayloadStore or its
        // 24h TTL has expired. Re-encrypting with the same message ID would advance the
        // Double Ratchet on our side without the peer receiving the previous ciphertext,
        // causing permanent ratchet desync. Mark as failed and signal the caller to
        // send fresh content under a new message ID instead.
        Log.error("❌ Retry: wire payload not found for \(capturedMessageId.prefix(8))… — payload expired, cannot re-send safely", category: "MessageRetryManager")
        message.deliveryStatus = .failed
        context.saveAndLog()
        onError("payload_expired")
    }
    
    // MARK: - Queued Messages Processing
    
    /// Send all queued messages for a chat (called when connection is restored)
    /// - Parameters:
    ///   - chat: Chat to process queued messages for
    ///   - recipientId: Recipient user ID
    ///   - currentUserId: Current user ID
    ///   - context: Core Data context
    func sendQueuedMessages(
        for chat: Chat,
        recipientId: String,
        currentUserId: String,
        context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        // Also retry failed messages that haven't exceeded the retry cap (e.g. dropped during ICE startup window)
        let queuedPredicate = NSPredicate(format: "chat == %@ AND deliveryStatusRaw == %d", chat, DeliveryStatus.queued.rawValue)
        let retryableFailed = NSPredicate(
            format: "chat == %@ AND deliveryStatusRaw == %d AND retryCount < %d",
            chat,
            DeliveryStatus.failed.rawValue,
            FeatureFlags.maxMessageRetryAttempts
        )
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [queuedPredicate, retryableFailed])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        guard let queuedMessages = try? context.fetch(fetchRequest) else {
            return
        }

        // Guard: if no session exists yet (e.g. we just got END_SESSION and are waiting as
        // RESPONDER), skip here — SessionCoordinator.sendSessionQueuedMessages() will call
        // us again once the new session is established.
        guard CryptoManager.shared.hasSession(for: recipientId) else {
            Log.debug("⏸️ sendQueuedMessages: no active session for \(recipientId.prefix(8))… — deferring until session is ready", category: "MessageRetryManager")
            return
        }

        Log.info("📤 Sending \(queuedMessages.count) queued messages (sequential to preserve ratchet state)", category: "MessageRetryManager")

        // Capture ids before the Task to avoid managed object threading issues
        let pendingIds: [String] = queuedMessages.map { $0.id }

        // Mark all as sending synchronously before the async work starts
        for message in queuedMessages where message.decryptedContent != nil {
            message.deliveryStatus = .sending
            message.retryCount += 1
            messageQueueManager.markMessageAsSending(message.id)
        }
        context.saveAndLog()

        // Send SEQUENTIALLY inside a single Task — Double Ratchet encryption must not run
        // concurrently for the same recipient to prevent ratchet state divergence and
        // concurrent Keychain write failures.
        Task {
            for messageId in pendingIds {
                do {
                    var finalStatus: DeliveryStatus = .sent
                    if let chunks = OutgoingWirePayloadStore.shared.loadChunks(baseMessageId: messageId) {
                        for (chunkId, wirePayload) in chunks {
                            let response = try await MessagingServiceClient.shared.sendMessage(
                                messageId: chunkId,
                                recipientId: recipientId,
                                senderId: currentUserId,
                                conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                                encryptedPayload: wirePayload,
                                timestamp: UInt64(Date().timeIntervalSince1970)
                            )
                            switch response.status.lowercased() {
                            case "failed":
                                finalStatus = response.retryable ? .queued : .failed
                            case "queued":
                                if finalStatus != .failed { finalStatus = .queued }
                            default:
                                break
                            }
                            if finalStatus == .failed { break }
                        }
                    } else {
                        // Wire payload not found — message predates OutgoingWirePayloadStore
                        // or its 24h TTL expired. Cannot re-encrypt: doing so would advance
                        // the Double Ratchet without the peer receiving the previous
                        // ciphertext, causing permanent desync. Mark failed; the user can
                        // manually resend via the retry button, which sends fresh content
                        // under a new message ID.
                        Log.error("⚠️ sendQueuedMessages: no wire payload for \(messageId.prefix(8))… — skipping (payload expired)", category: "MessageRetryManager")
                        finalStatus = .failed
                    }
                    await MainActor.run {
                        let fr = Message.fetchRequest()
                        fr.predicate = NSPredicate(format: "id == %@", messageId)
                        fr.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fr).first else { return }
                        liveMsg.deliveryStatus = finalStatus
                        context.saveAndLog()
                        if finalStatus == .sent || finalStatus == .delivered {
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                        } else if finalStatus == .failed {
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                        }
                        Log.debug("📮 Re-sent queued message via gRPC: \(messageId) status=\(finalStatus) (attempt \(liveMsg.retryCount))", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        Log.error("Failed to re-send queued message \(messageId): \(error)", category: "MessageRetryManager")
                        let fr = Message.fetchRequest()
                        fr.predicate = NSPredicate(format: "id == %@", messageId)
                        fr.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fr).first else { return }
                        let code = (error as? RPCError).map { String(describing: $0.code).lowercased() } ?? ""
                        let isRetryableTransport = code == "deadlineexceeded" || code == "unavailable" || code == "cancelled"
                        liveMsg.deliveryStatus = isRetryableTransport ? .queued : .failed
                        context.saveAndLog()
                    }
                }
            }
        }
    }
}
