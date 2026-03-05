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
        try? context.save()

        Log.info("🔄 Retrying message \(message.id.prefix(8))... (attempt \(message.retryCount))", category: "MessageRetryManager")

        // ✅ Update existing message status instead of creating new one
        message.deliveryStatus = .sending
        try? context.save()

        // ✅ Re-encrypt and resend using SAME message ID
        do {
            let components = try CryptoManager.shared.encryptMessage(decryptedText, for: recipientId)
            let encryptedPayload = try WirePayloadCoder.encode(components)

            Task {
                do {
                    let response = try await MessagingServiceClient.shared.sendMessage(
                        messageId: message.id,
                        recipientId: recipientId,
                        senderId: message.fromUserId,
                        conversationId: ConversationId.direct(myUserId: message.fromUserId, theirUserId: recipientId),
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
                        
                        message.deliveryStatus = deliveryStatus
                        try? context.save()
                        Log.info("✅ Message retry successful: \(response.messageId), status: \(deliveryStatus)", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        // ✅ Keep existing message as failed
                        message.deliveryStatus = .failed
                        try? context.save()
                        Log.error("❌ Message retry failed: \(error.localizedDescription)", category: "MessageRetryManager")
                        onError("Failed to send message: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            // ✅ Encryption failed - mark as failed
            message.deliveryStatus = .failed
            try? context.save()
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
        let chatPredicate = NSPredicate(format: "chat == %@ AND deliveryStatusRaw == %d", chat, DeliveryStatus.queued.rawValue)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        guard let queuedMessages = try? context.fetch(fetchRequest) else {
            return
        }

        Log.info("📤 Sending \(queuedMessages.count) queued messages", category: "MessageRetryManager")

        for message in queuedMessages {
            // Re-encrypt and send
            guard let decryptedText = message.decryptedContent else {
                continue
            }

            let plan = ChunkedMessageSender.shared.buildPlan(plaintext: decryptedText, messageId: UUID(uuidString: message.id) ?? UUID())

            message.deliveryStatus = .sending
            message.retryCount += 1
            try? context.save()

            // ✅ Send via gRPC
            Task {
                do {
                    let _ = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: UInt64(Date().timeIntervalSince1970)
                    )
                    await MainActor.run {
                        message.deliveryStatus = .sent
                        try? context.save()
                        Log.debug("📮 Re-sent queued message via gRPC: \(message.id) (attempt \(message.retryCount))", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        Log.error("Failed to re-send queued message: \(error)", category: "MessageRetryManager")
                        message.deliveryStatus = .failed
                        try? context.save()
                    }
                }
            }
            messageQueueManager.markMessageAsSending(message.id)
            Log.debug("📮 Re-sent queued message: \(message.id) (attempt \(message.retryCount))", category: "MessageRetryManager")
        }
    }
}
