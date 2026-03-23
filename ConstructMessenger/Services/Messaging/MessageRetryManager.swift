import Foundation
import CoreData
import os.log

/// Manages message retry logic for failed and queued messages
@MainActor
class MessageRetryManager {
    
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

        guard let decryptedText = message.decryptedContent else {
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

        // ✅ Re-encrypt and resend using SAME message ID
        do {
            let capturedMessageId = message.id
            let capturedSenderId = message.fromUserId
            let components = try CryptoManager.shared.encryptMessage(decryptedText, for: recipientId)
            let encryptedPayload = try WirePayloadCoder.encode(components)

            Task {
                do {
                    let response = try await MessagingServiceClient.shared.sendMessage(
                        messageId: capturedMessageId,
                        recipientId: recipientId,
                        senderId: capturedSenderId,
                        conversationId: ConversationId.direct(myUserId: capturedSenderId, theirUserId: recipientId),
                        encryptedPayload: encryptedPayload,
                        timestamp: UInt64(Date().timeIntervalSince1970)
                    )
                    
                    await MainActor.run {
                        // ✅ Use server-provided status
                        let deliveryStatus: DeliveryStatus
                        switch response.status.lowercased() {
                        case "delivered": deliveryStatus = .delivered
                        case "queued": deliveryStatus = .queued
                        default: deliveryStatus = .sent
                        }
                        let fetchRequest = Message.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                        fetchRequest.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fetchRequest).first else { return }
                        liveMsg.deliveryStatus = deliveryStatus
                        context.saveAndLog()
                        Log.info("✅ Message retry successful: \(response.messageId), status: \(deliveryStatus)", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        let fetchRequest = Message.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                        fetchRequest.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fetchRequest).first else { return }
                        liveMsg.deliveryStatus = .failed
                        context.saveAndLog()
                        Log.error("❌ Message retry failed: \(error.localizedDescription)", category: "MessageRetryManager")
                        onError("Failed to send message: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            // ✅ Encryption failed - mark as failed
            message.deliveryStatus = .failed
            context.saveAndLog()
            onError("Failed to encrypt message: \(error.localizedDescription)")
            Log.error("❌ Retry encryption failed: \(error.localizedDescription)", category: "MessageRetryManager")
        }
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

        Log.info("📤 Sending \(queuedMessages.count) queued messages (sequential to preserve ratchet state)", category: "MessageRetryManager")

        // Capture IDs and plans before the Task to avoid managed object threading issues
        let pendingItems: [(id: String, plan: ChunkedMessagePlan)] = queuedMessages.compactMap { message in
            guard let decryptedText = message.decryptedContent else { return nil }
            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: decryptedText,
                messageId: UUID(uuidString: message.id) ?? UUID()
            )
            return (id: message.id, plan: plan)
        }

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
            for item in pendingItems {
                do {
                    let _ = try await ChunkedMessageSender.shared.sendChunks(
                        plan: item.plan,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: UInt64(Date().timeIntervalSince1970)
                    )
                    await MainActor.run {
                        let fr = Message.fetchRequest()
                        fr.predicate = NSPredicate(format: "id == %@", item.id)
                        fr.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fr).first else { return }
                        liveMsg.deliveryStatus = .sent
                        context.saveAndLog()
                        Log.debug("📮 Re-sent queued message via gRPC: \(item.id) (attempt \(liveMsg.retryCount))", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        Log.error("Failed to re-send queued message \(item.id): \(error)", category: "MessageRetryManager")
                        let fr = Message.fetchRequest()
                        fr.predicate = NSPredicate(format: "id == %@", item.id)
                        fr.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fr).first else { return }
                        liveMsg.deliveryStatus = .failed
                        context.saveAndLog()
                    }
                }
            }
        }
    }
}
