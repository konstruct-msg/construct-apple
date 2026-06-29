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
        // Retry for failed or queued messages
        guard message.canRetry || message.deliveryStatus == .queued else {
            Log.info("Message cannot be retried", category: "MessageRetryManager")
            return
        }

        // Ensure decrypted content exists before proceeding
        guard message.hasDecryptedContent else {
            Log.error("Cannot retry - no decrypted content", category: "MessageRetryManager")
            return
        }

        // Increment retry count
        message.retryCount += 1
        context.saveAndLog()

        Log.info("Retrying message \(message.id.prefix(8))... (attempt \(message.retryCount))", category: "MessageRetryManager")

        // Update existing message status instead of creating new one
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
                        Log.info("Message retry completed: \(capturedMessageId) status=\(finalStatus)\(ecStr)\(raStr)", category: "MessageRetryManager")
                        if finalStatus == .queued, maxRetryAfterMs > 0 {
                            Log.info("Rate-limited retry — will reschedule in \(maxRetryAfterMs)ms for \(capturedMessageId.prefix(8))", category: "MessageRetryManager")
                        }
                    }
                } catch {
                    await MainActor.run {
                        let fetchRequest = Message.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                        fetchRequest.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fetchRequest).first else { return }
                        let isRetryableTransport: Bool = {
                            if error is GRPCClientError { return true }
                            if let rpc = error as? RPCError {
                                return rpc.code == .deadlineExceeded || rpc.code == .unavailable || rpc.code == .cancelled
                            }
                            return false
                        }()
                        liveMsg.deliveryStatus = isRetryableTransport ? .queued : .failed
                        context.saveAndLog()
                        if isRetryableTransport {
                            Log.info("Retry transport failure — queued \(capturedMessageId.prefix(8))… for later", category: "MessageRetryManager")
                        } else {
                            Log.error("Message retry failed: \(error.localizedDescription)", category: "MessageRetryManager")
                            onError("Failed to send message: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return
        }

        // Wire payload not found — it predates OutgoingWirePayloadStore, its 24h TTL has expired,
        // or it was purged after a zombie-session re-establishment. Re-encrypt the recoverable
        // plaintext under the CURRENT session with a FRESH wire id (re-using the same id would
        // advance our ratchet without the peer ever getting the old ciphertext → desync). Falls
        // back to .failed (and the legacy `payload_expired` signal) for media / unrecoverable.
        Log.info("Retry: wire payload gone for \(capturedMessageId.prefix(8))… — re-encrypting under current session", category: "MessageRetryManager")
        Task { [weak self] in
            guard let self else { return }
            let status = await self.reencryptAndSend(messageId: capturedMessageId, recipientId: recipientId, senderId: capturedSenderId, context: context)
            await MainActor.run {
                let fr = Message.fetchRequest()
                fr.predicate = NSPredicate(format: "id == %@", capturedMessageId)
                fr.fetchLimit = 1
                guard let liveMsg = try? context.fetch(fr).first else { return }
                liveMsg.deliveryStatus = status
                context.saveAndLog()
                if status == .sent || status == .delivered || status == .failed {
                    OutgoingWirePayloadStore.shared.remove(baseMessageId: capturedMessageId)
                }
                if status == .failed {
                    onError("payload_expired")
                }
                Log.info("Retry re-encrypt result for \(capturedMessageId.prefix(8))…: \(status)", category: "MessageRetryManager")
            }
        }
    }
    
    // MARK: - Global Queued Messages Processing

    /// Process queued messages for ALL chats — called from the background service layer
    /// so retry works even when no chat screen is open.
    func processAllQueuedMessages(currentUserId: String, context: NSManagedObjectContext) {
        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        guard let chats = try? context.fetch(fetchRequest) else { return }

        for chat in chats {
            guard let recipientId = chat.otherUser?.id, !recipientId.isEmpty else { continue }
            let queuedCheck = NSFetchRequest<Message>(entityName: "Message")
            queuedCheck.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "chat == %@ AND deliveryStatusRaw == %d", chat, DeliveryStatus.queued.rawValue),
                NSPredicate(format: "chat == %@ AND deliveryStatusRaw == %d AND retryCount < %d",
                            chat, DeliveryStatus.failed.rawValue, FeatureFlags.maxMessageRetryAttempts)
            ])
            queuedCheck.fetchLimit = 1
            guard (try? context.count(for: queuedCheck)) ?? 0 > 0 else { continue }
            sendQueuedMessages(
                for: chat,
                recipientId: recipientId,
                currentUserId: currentUserId,
                context: context
            )
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
        // Also retry failed messages that haven't exceeded the retry cap (e.g. dropped during VEIL startup window)
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

        // Guard: no live session for this contact.
        //
        // If the crypto core is ready, the absence is real (the "zombie session"): any stored
        // wire payloads are bound to a dead/replaced ratchet the peer can no longer decrypt, so
        // we purge them and force an INITIATOR re-establish. We may be the natural RESPONDER for a
        // purely-outbound peer, where prewarm (INITIATOR-only) never fires and no inbound traffic
        // triggers a RESPONDER init — without this nudge the queue would defer forever. We defer
        // THIS tick; the queued flush re-runs via sendSessionQueuedMessages once session_ready
        // arrives, and by then the purged payloads route through the re-encrypt path below.
        //
        // If the core is NOT ready, hasSession returns false for every contact (startup race);
        // a plain defer is correct — a later forceReconnect re-triggers us once the core builds.
        guard CryptoManager.shared.hasSession(for: recipientId) else {
            if CryptoManager.shared.isCoreReady {
                for message in queuedMessages {
                    OutgoingWirePayloadStore.shared.remove(baseMessageId: message.id)
                }
                Log.info("sendQueuedMessages: no session for \(recipientId.prefix(8))… (core ready) — purged \(queuedMessages.count) orphaned payload(s), forcing re-establish", category: "MessageRetryManager")
                SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: recipientId)
            } else {
                Log.debug("sendQueuedMessages: no active session for \(recipientId.prefix(8))… and core not ready — deferring", category: "MessageRetryManager")
            }
            return
        }

        let pendingIds = prepareMessagesForGlobalRetry(queuedMessages, context: context)

        // Messages whose stored wire payload is gone — TTL expiry, or purged above after a
        // zombie-session re-establishment — but whose plaintext is still recoverable. The session
        // is live again here, so re-encrypt them under the current ratchet with a fresh wire id.
        let reencryptIds = queuedMessages
            .filter { OutgoingWirePayloadStore.shared.loadChunks(baseMessageId: $0.id) == nil && $0.hasDecryptedContent }
            .map { $0.id }

        guard !pendingIds.isEmpty || !reencryptIds.isEmpty else {
            Log.info("sendQueuedMessages: no queued messages with reusable wire payload or recoverable plaintext for \(recipientId.prefix(8))… — preserving local queue", category: "MessageRetryManager")
            return
        }

        // Mark the re-encrypt targets as sending up front so the UI reflects progress and the
        // retry count advances exactly once per tick (mirrors prepareMessagesForGlobalRetry).
        for message in queuedMessages where reencryptIds.contains(message.id) {
            message.deliveryStatus = .sending
            message.retryCount += 1
            messageQueueManager.markMessageAsSending(message.id)
        }

        Log.info("Sending \(pendingIds.count) queued (stored ciphertext) + \(reencryptIds.count) re-encrypted message(s) (sequential to preserve ratchet state)", category: "MessageRetryManager")
        context.saveAndLog()

        // Send SEQUENTIALLY inside a single Task — Double Ratchet encryption must not run
        // concurrently for the same recipient to prevent ratchet state divergence and
        // concurrent Keychain write failures. Stored-ciphertext resends (no ratchet mutation)
        // go first, then re-encrypted messages (which advance the ratchet to the newest numbers).
        Task { [weak self] in
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
                        // The payload disappeared after preflight (e.g. TTL expiry). Preserve
                        // the local queue so the user can still manually retry as a fresh send.
                        Log.error("sendQueuedMessages: wire payload vanished for \(messageId.prefix(8))… after preflight — restoring queued state", category: "MessageRetryManager")
                        finalStatus = .queued
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
                        Log.debug("Re-sent queued message via gRPC: \(messageId) status=\(finalStatus) (attempt \(liveMsg.retryCount))", category: "MessageRetryManager")
                    }
                } catch {
                    await MainActor.run {
                        Log.error("Failed to re-send queued message \(messageId): \(error)", category: "MessageRetryManager")
                        let fr = Message.fetchRequest()
                        fr.predicate = NSPredicate(format: "id == %@", messageId)
                        fr.fetchLimit = 1
                        guard let liveMsg = try? context.fetch(fr).first else { return }
                        let isRetryableTransport: Bool = {
                            if error is GRPCClientError { return true }
                            if let rpc = error as? RPCError {
                                return rpc.code == .deadlineExceeded || rpc.code == .unavailable || rpc.code == .cancelled
                            }
                            return false
                        }()
                        liveMsg.deliveryStatus = isRetryableTransport ? .queued : .failed
                        context.saveAndLog()
                    }
                }
            }

            // Re-encrypt pass: messages whose ciphertext was orphaned by a dead session.
            for messageId in reencryptIds {
                guard let self else { break }
                let status = await self.reencryptAndSend(messageId: messageId, recipientId: recipientId, senderId: currentUserId, context: context)
                await MainActor.run {
                    let fr = Message.fetchRequest()
                    fr.predicate = NSPredicate(format: "id == %@", messageId)
                    fr.fetchLimit = 1
                    guard let liveMsg = try? context.fetch(fr).first else { return }
                    liveMsg.deliveryStatus = status
                    context.saveAndLog()
                    if status == .sent || status == .delivered || status == .failed {
                        OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                    }
                    Log.info("Re-encrypted queued message \(messageId.prefix(8))… → \(status)", category: "MessageRetryManager")
                }
            }
        }
    }

    /// Re-encrypts a queued/failed message's recoverable plaintext under the CURRENT session with a
    /// FRESH wire message id and sends it. Used when the original wire payload is gone (TTL expiry,
    /// or purged after a zombie-session re-establishment) — the stale ciphertext was bound to a
    /// dead ratchet the peer can no longer decrypt.
    ///
    /// Re-using the same wire id would advance our ratchet without the peer ever receiving the old
    /// ciphertext (and risks dedup-drop on the peer) → permanent desync. A fresh wire UUID is safe:
    /// the new ratchet output is a normal forward message the peer's DR handles via skipped keys.
    ///
    /// Only text content (content_type 0) is re-encryptable — media wire plaintext is a binary
    /// album proto not reconstructable from the persisted model, so media returns `.failed` for
    /// manual resend. Returns the resulting status; the caller persists it on MainActor.
    private func reencryptAndSend(
        messageId: String,
        recipientId: String,
        senderId: String,
        context: NSManagedObjectContext
    ) async -> DeliveryStatus {
        // Fetch on MainActor (this method is @MainActor); the Message stays local so no
        // non-Sendable NSManagedObject ever crosses the await boundary into the caller.
        let fr = Message.fetchRequest()
        fr.predicate = NSPredicate(format: "id == %@", messageId)
        fr.fetchLimit = 1
        guard let message = try? context.fetch(fr).first else {
            Log.error("reencryptAndSend: message \(messageId.prefix(8))… vanished before re-encrypt", category: "MessageRetryManager")
            return .failed
        }

        guard CryptoManager.shared.hasSession(for: recipientId) else {
            // Session vanished again before we got here — nudge a re-establish and keep it queued.
            SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: recipientId)
            return .queued
        }
        guard message.contentType != .media else {
            Log.info("reencryptAndSend: \(messageId.prefix(8))… is media — cannot reconstruct wire plaintext, failing", category: "MessageRetryManager")
            return .failed
        }
        let text = message.displayText
        guard !text.isEmpty, !MessageContentType.isControlPayload(text) else {
            Log.error("reencryptAndSend: \(messageId.prefix(8))… has no recoverable plaintext — failing", category: "MessageRetryManager")
            return .failed
        }

        var textMsg = Shared_Proto_Messaging_V1_TextMessage()
        textMsg.text = text
        if let replyId = message.replyToMessageId, !replyId.isEmpty {
            var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
            quoted.messageID = replyId
            quoted.textPreview = message.replyToContent ?? ""
            textMsg.quoted = quoted
        }
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = textMsg
        guard let plaintext = try? content.serializedData(), !plaintext.isEmpty else {
            Log.error("reencryptAndSend: failed to serialize MessageContent for \(messageId.prefix(8))…", category: "MessageRetryManager")
            return .failed
        }

        // Drop any orphaned ciphertext, then re-chunk under a FRESH wire UUID. The local payload
        // store and delivery tracking stay keyed by the original baseMessageId (UI continuity);
        // only the wire-level chunk ids are new.
        OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
        let plan = ChunkedMessageSender.shared.buildPlan(plaintext: plaintext, messageId: UUID())
        guard !plan.payloads.isEmpty else {
            Log.error("reencryptAndSend: empty chunk plan for \(messageId.prefix(8))…", category: "MessageRetryManager")
            return .failed
        }

        do {
            let aggregated = try await OutboundMessagePipeline.shared.sendChunks(
                plan: plan,
                baseMessageId: messageId,
                senderId: senderId,
                recipientId: recipientId,
                conversationId: ConversationId.direct(myUserId: senderId, theirUserId: recipientId),
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            switch aggregated.status.lowercased() {
            case "failed":    return aggregated.retryable ? .queued : .failed
            case "queued":    return .queued
            case "delivered": return .delivered
            default:          return .sent
            }
        } catch {
            let isRetryableTransport: Bool = {
                if error is GRPCClientError { return true }
                if let rpc = error as? RPCError {
                    return rpc.code == .deadlineExceeded || rpc.code == .unavailable || rpc.code == .cancelled
                }
                return false
            }()
            Log.error("reencryptAndSend: send failed for \(messageId.prefix(8))…: \(error.localizedDescription)", category: "MessageRetryManager")
            return isRetryableTransport ? .queued : .failed
        }
    }

    func prepareMessagesForGlobalRetry(_ messages: [Message], context: NSManagedObjectContext) -> [String] {
        var pendingIds: [String] = []
        pendingIds.reserveCapacity(messages.count)

        for message in messages where message.hasDecryptedContent {
            guard OutgoingWirePayloadStore.shared.loadChunks(baseMessageId: message.id) != nil else {
                switch message.deliveryStatus {
                case .queued:
                    Log.info(
                        "sendQueuedMessages: preserving queued \(message.id.prefix(8))… — no wire payload, needs fresh resend path",
                        category: "MessageRetryManager"
                    )
                case .failed:
                    Log.debug(
                        "sendQueuedMessages: skipping failed \(message.id.prefix(8))… — no wire payload for safe global retry",
                        category: "MessageRetryManager"
                    )
                default:
                    break
                }
                continue
            }

            message.deliveryStatus = .sending
            message.retryCount += 1
            messageQueueManager.markMessageAsSending(message.id)
            pendingIds.append(message.id)
        }

        return pendingIds
    }
}
