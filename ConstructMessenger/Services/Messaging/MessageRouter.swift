//
//  MessageRouter.swift
//  Construct Messenger
//
//  Routes and processes incoming messages
//  Extracted from ChatsViewModel as part of Phase 1.4 refactoring
//  Created on 2026-02-01
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

/// Routes and processes incoming messages
@MainActor
class MessageRouter {
    
    // MARK: - Core Data
    
    private var viewContext: NSManagedObjectContext?
    
    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    // MARK: - Callbacks
    
    /// Called when a new chat is created
    var onChatCreated: ((Chat) -> Void)?
    
    /// Called when username needs updating
    var onUsernameUpdateNeeded: ((String) -> Void)?
    
    /// Called when public key bundle is needed for session initialization
    var onPublicKeyBundleNeeded: ((String, ChatMessage) -> Void)?

    /// Called when receiver cannot init session (messageNumber > 0, no session).
    /// Caller should send END_SESSION to that userId so the sender restarts from messageNumber=0.
    var onEndSessionNeeded: ((String) -> Void)?

    /// Called when an END_SESSION *from* a peer has been processed (session cleared).
    /// Receiver should re-initiate if it is the natural INITIATOR (lower userId).
    var onEndSessionReceived: ((String) -> Void)?

    /// Called when an existing session failed to decrypt a `messageNumber==0` message.
    /// The remote peer re-keyed — caller should archive the current session and
    /// attempt `initReceivingSession` with the supplied message as the new X3DH init.
    var onSessionHealNeeded: ((String, ChatMessage) -> Void)?

    /// Called when this device wins the tie-break (lower userId restores INITIATOR session).
    /// Receiver should send END_SESSION to the loser and then send a session establishment
    /// ping so the loser can immediately become RESPONDER without user action.
    var onTieBreakWin: ((String) -> Void)?

    /// Called when a receipt should be sent via the stream.
    /// Provides message IDs, the original sender's user ID (for server routing), and receipt status.
    var onReceiptNeeded: (([String], String, Shared_Proto_Signaling_V1_ReceiptStatus) -> Void)?

    private let chunkReassembler = ChunkedMessageReassembler.shared
    
    // MARK: - Message Routing
    
    /// Route incoming message to appropriate handler
    /// - Parameters:
    ///   - message: Incoming chat message
    ///   - context: Core Data context
    ///   - pendingMessages: Dictionary of pending first messages
    func routeIncomingMessage(
        _ message: ChatMessage,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        let otherUserId = message.from == currentUserId ? message.to : message.from
        
        #if DEBUG
        Log.debug("📥 INCOMING message RAW from server:", category: "MessageRouter")
        Log.debug("   messageId: \(message.id)", category: "MessageRouter")
        Log.debug("   from: \(message.from)", category: "MessageRouter")
        Log.debug("   to: \(message.to)", category: "MessageRouter")
        Log.debug("   messageNumber: \(message.messageNumber)", category: "MessageRouter")
        Log.debug("   oneTimePreKeyId: \(message.oneTimePreKeyId)", category: "MessageRouter")
        Log.debug("   ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "MessageRouter")
        let ephemeralPreview = message.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined()
        Log.debug("   ephemeralPublicKey preview: \(ephemeralPreview)...", category: "MessageRouter")
        Log.debug("   content (padded): \(message.content.count) chars", category: "MessageRouter")
        Log.debug("   content preview: \(message.content.prefix(32))...", category: "MessageRouter")
        Log.debug("   isEndSession: \(message.isEndSession)", category: "MessageRouter")
        if !message.editsMessageId.isEmpty {
            Log.debug("   editsMessageId: \(message.editsMessageId)", category: "MessageRouter")
        }
        #endif
        
        // 1. Skip if already processed — applies to ALL messages including END_SESSION.
        //    Without this, the same END_SESSION is processed twice (pending queue + stream).
        if PersistentACKStore.shared.isProcessed(message.id, in: context) {
            Log.debug("⏭️ Skipping already-processed message \(message.id.prefix(8))… (ACK store)", category: "MessageRouter")
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // 2. SENDER_SYNC — copy of own outgoing message from another device.
        //    Route separately: decrypt with per-device session, save as outgoing in the
        //    conversation with the original partner (extracted from conversationId).
        if message.isSenderSync {
            PersistentACKStore.shared.markProcessed(message.id, senderId: message.from, in: context)
            handleSenderSync(message, in: context)
            onReceiptNeeded?([message.id], message.from, .delivered)
            return
        }

        // 3. Check if this is an END_SESSION control message
        if message.isEndSession {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.info("🛑 Received END_SESSION from \(otherUserId)", category: "MessageRouter")
            handleEndSession(from: otherUserId, in: context, pendingMessages: &pendingMessages)
            // ACK so the server removes it from the pending queue
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // 3. Skip if already saved to Core Data (deduplication for duplicate deliveries)
        let existingFetch = Message.fetchRequest()
        existingFetch.predicate = NSPredicate(format: "id == %@", message.id)
        existingFetch.fetchLimit = 1
        if (try? context.fetch(existingFetch))?.first != nil {
            Log.debug("⏭️ Skipping already-saved message \(message.id.prefix(8))…", category: "MessageRouter")
            return
        }

        // 4. Handle messages from contacts whose chat was explicitly deleted.
        //    messageNumber=0 means the sender fetched our *current* public keys (via a fresh invite)
        //    and started a new session — this is a legitimate re-contact, so clear the deleted flag
        //    and process normally (a new chat will be created by findOrCreateChat below).
        //    messageNumber>0 is an old broken session we no longer have keys for — skip it.
        //    Exception: if this exact message is already in our pending queue (a previous heal
        //    attempt started and failed), the server is re-delivering a stuck undecryptable message.
        //    Do NOT resurrect the contact in that case — just ACK and discard.
        if DeletedContactsStore.shared.isDeleted(otherUserId) {
            if message.messageNumber == 0 {
                // Guard: don't resurrect a deleted contact for a message we already queued
                // but couldn't decrypt. This prevents an infinite delete→re-appear loop when
                // the server keeps re-delivering stuck undecryptable messages.
                if pendingMessages[otherUserId]?.contains(where: { $0.id == message.id }) == true {
                    Log.debug("⏭️ Skipping stale pending message \(message.id.prefix(8))… from deleted contact — not resurrecting", category: "MessageRouter")
                    onReceiptNeeded?([message.id], otherUserId, .delivered)
                    return
                }
                Log.info("♻️ Fresh session (msgNum=0) from previously-deleted contact \(otherUserId.prefix(8))… — clearing deleted flag", category: "MessageRouter")
                DeletedContactsStore.shared.remove(otherUserId)
                // Fall through to normal processing below.
            } else {
                Log.debug("⏭️ Skipping old-session message (msgNum=\(message.messageNumber)) from deleted contact \(otherUserId.prefix(8))…", category: "MessageRouter")
                return
            }
        }

        // 5. Find or create chat
        let (chat, isNewChat) = findOrCreateChat(for: otherUserId, in: context)
        
        // 6. Check if we have a session for this user.
        // Guard against startup race: the deferred restoreRecentSessions() may not have run yet
        // if Core Data wasn't ready. Calling restoreSession(for:) here is a targeted, synchronous
        // Keychain load for exactly this contact — a no-op if already in memory (~1µs), or a fast
        // import (~5-10ms) if the session key is in Keychain but not yet loaded into the Rust core.
        // This prevents the false "session out of sync" banner that fires when the gRPC stream
        // delivers a mid-ratchet message (msgNum > 0) before sessions have been fully restored.
        CryptoManager.shared.restoreSession(for: otherUserId)
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)
        Log.info("🔐 SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")
        
        let decryptedContent: String
        if !hasSession {
            // First message from this user - need to initialize receiving session
            handleFirstMessage(
                message,
                from: otherUserId,
                chat: chat,
                isNewChat: isNewChat,
                in: context,
                pendingMessages: &pendingMessages
            )
            return
        } else {
            // M5: Try routing through Rust orchestrator first
            if let core = CryptoManager.shared.orchestratorCore,
               let event = buildIncomingEvent(message: message, otherUserId: otherUserId) {
                do {
                    PerformanceMetrics.shared.messageDecryptStart(messageId: message.id)
                    let actions = try core.handleEvent(event: event)
                    PerformanceMetrics.shared.messageDecryptEnd(messageId: message.id)
                    if actions.contains(where: { if case .messageDecrypted = $0 { return true }; return false }) {
                        executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
                        return
                    }
                    // No MessageDecrypted — fall through to Swift path (tie-break, heal, archive restore)
                    Log.debug("⚠️ handleEvent returned no MessageDecrypted for \(message.id.prefix(8))… — falling back to Swift path", category: "MessageRouter")
                } catch {
                    Log.error("❌ handleEvent failed for \(message.id.prefix(8))…: \(error) — falling back to Swift path", category: "MessageRouter")
                }
            }

            // Swift fallback: handles tie-break, heal, archived-session decrypt
            decryptedContent = handleMessageWithSession(
                message,
                from: otherUserId,
                chat: chat,
                in: context,
                pendingMessages: &pendingMessages
            ) ?? ""
            
            if decryptedContent.isEmpty {
                if isNewChat { context.delete(chat) }
                return
            }
        }

        switch chunkReassembler.process(decryptedText: decryptedContent) {
        case .legacy(let text), .complete(let text):
            return handleResolvedMessage(
                text,
                for: message,
                from: otherUserId,
                chat: chat,
                in: context
            )
        case .incomplete:
            Log.debug("🧩 Chunked message incomplete, waiting for more chunks", category: "MessageRouter")
            return
        case .invalid(let reason):
            Log.error("❌ Invalid chunked message: \(reason)", category: "MessageRouter")
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }
    }

    // MARK: - Rust Orchestrator Routing (M5)

    /// Build a typed `CfeIncomingEvent.messageReceived` from a server message.
    private func buildIncomingEvent(message: ChatMessage, otherUserId: String) -> CfeIncomingEvent? {
        guard !message.rawPayload.isEmpty else {
            Log.error("❌ buildIncomingEvent: empty rawPayload for \(message.id.prefix(8))… — falling back to JSON path", category: "MessageRouter")
            return buildIncomingEventLegacy(message: message, otherUserId: otherUserId)
        }

        return .messageReceived(
            messageId: message.id,
            from: otherUserId,
            data: message.rawPayload,
            msgNum: message.messageNumber,
            kemCt: message.kemCiphertext,
            otpkId: message.kyberOtpkId,
            isControl: false,
            contentType: message.contentType
        )
    }

    /// Legacy JSON path — only used when rawPayload is unavailable (e.g. old healing records).
    private func buildIncomingEventLegacy(message: ChatMessage, otherUserId: String) -> CfeIncomingEvent? {
        let unpaddedContent = MessagePadding.unpadCiphertextBase64(message.content)
        guard let sealedBox = Data(base64Encoded: unpaddedContent), sealedBox.count >= 12 else {
            Log.error("❌ buildIncomingEventLegacy: cannot decode content for \(message.id.prefix(8))…", category: "MessageRouter")
            return nil
        }

        let nonce      = Array(sealedBox.prefix(12))
        let ciphertext = Array(sealedBox.dropFirst(12))
        let dhPublicKey = Array(message.ephemeralPublicKey)

        let wireMessage: [String: Any] = [
            "dh_public_key": dhPublicKey.map { Int($0) },
            "message_number": Int(message.messageNumber),
            "ciphertext": ciphertext.map { Int($0) },
            "nonce": nonce.map { Int($0) },
            "previous_chain_length": 0,
            "suite_id": 1
        ]
        guard let wireJsonData = try? JSONSerialization.data(withJSONObject: wireMessage) else { return nil }

        return .messageReceived(
            messageId: message.id,
            from: otherUserId,
            data: wireJsonData,
            msgNum: message.messageNumber,
            kemCt: message.kemCiphertext,
            otpkId: message.kyberOtpkId,
            isControl: false,
            contentType: message.contentType
        )
    }

    /// Execute typed actions returned by `OrchestratorCore.handleEvent`.
    private func executeRustActions(
        _ actions: [CfeAction],
        for message: ChatMessage,
        chat: Chat,
        otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        for action in actions {
            switch action {
            case .messageDecrypted(let contactId, _, let plaintext):
                _ = contactId
                checkUsernameUpdate(for: otherUserId, chat: chat, in: context)
                switch chunkReassembler.process(decryptedText: plaintext) {
                case .legacy(let text), .complete(let text):
                    handleResolvedMessage(text, for: message, from: otherUserId, chat: chat, in: context)
                case .incomplete:
                    Log.debug("🧩 Chunked message incomplete, waiting for more chunks", category: "MessageRouter")
                case .invalid(let reason):
                    Log.error("❌ Invalid chunked message: \(reason)", category: "MessageRouter")
                    onReceiptNeeded?([message.id], otherUserId, .delivered)
                }

            case .saveSessionToSecureStore(let key, let data):
                handleStorageAction(key: key, data: [UInt8](data))

            case .notifyNewMessage:
                break // Notification triggered by saveMessage inside handleResolvedMessage

            case .persistMessage:
                // Legacy ACK action — superseded by persistAck. No-op.
                break

            case .persistAck(let messageId, _):
                // Rust core signals that this message should be persisted to the ACK store.
                // Swift-side PersistentACKStore already handles this in handleResolvedMessage,
                // but we also pre-populate the Rust cache on the M5 path.
                _ = CryptoManager.shared.orchestratorCore?.ackMarkProcessed(messageId: messageId)

            case .pruneAckStore:
                // Platform prunes its own ACK store on the gc_sweep timer.
                // Nothing to do here — Swift handles this via ChatsViewModel.pruneExpired.
                break

            case .callSignalDecrypted(let contactId, _, let protoBytes):
                // Rust decrypted a content_type=12 WirePayload — dispatch the raw proto bytes to CallManager.
                if let signal = CallManager.decodeSignalProto(from: protoBytes) {
                    CallManager.shared.handleCallSignalProto(from: contactId, signal: signal)
                } else {
                    Log.error("❌ callSignalDecrypted: failed to decode WebRTCSignal proto from \(contactId.prefix(8))…", category: "MessageRouter")
                }

            case .notifyError(let code, let msg):
                Log.error("❌ Rust orchestrator error [\(code)]: \(msg)", category: "MessageRouter")

            default:
                Log.debug("🔷 Unhandled Rust action in M5 path: \(action)", category: "MessageRouter")
            }
        }
    }

    /// Execute only storage actions from a typed Rust action list (no ChatMessage context needed).
    private func executeStorageActions(_ actions: [CfeAction]) {
        for action in actions {
            if case .saveSessionToSecureStore(let key, let data) = action {
                handleStorageAction(key: key, data: [UInt8](data))
            }
        }
    }

    /// Unified handler for a `SaveSessionToSecureStore` action.
    ///
    /// Key conventions (established by `session_lifecycle.rs`):
    /// - `"session_<contactId>"` + non-empty bytes → save hot session to Keychain
    /// - `"session_<contactId>"` + empty bytes    → delete sentinel: clear Keychain + UserDefaults
    /// - `"archive_<contactId>"` + bytes          → accept pre-archived session from Rust
    /// - `"pq_deferred_<contactId>"` + bytes      → persist deferred PQ contribution
    /// - `"pq_deferred_<contactId>"` + empty      → delete stored PQ contribution
    private func handleStorageAction(key: String, data rawBytes: [UInt8]) {
        if key.hasPrefix("session_") {
            let contactId = String(key.dropFirst("session_".count))
            if rawBytes.isEmpty {
                // Delete sentinel: Rust archived the session and removed it from memory.
                KeychainManager.shared.deleteSession(for: contactId)
                UserDefaults.standard.removeObject(forKey: "construct.session.suite.\(contactId)")
                Log.debug("🗑️ Deleted hot session for \(contactId.prefix(8))… (Rust archive_session)", category: "MessageRouter")
                CryptoManager.shared.saveOrchestratorStateCFE()
            } else {
                CryptoManager.shared.saveSessionToKeychainPublic(for: contactId)
                CryptoManager.shared.saveOrchestratorStateCFE()
            }
        } else if key.hasPrefix("archive_") {
            let contactId = String(key.dropFirst("archive_".count))
            CryptoManager.shared.acceptRustSessionArchive(contactId: contactId, sessionJsonBytes: rawBytes)
            CryptoManager.shared.saveOrchestratorStateCFE()
        } else if key.hasPrefix("pq_deferred_") {
            let storageKey = "construct.pq_deferred.\(String(key.dropFirst("pq_deferred_".count)))"
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteData(forKey: storageKey)
                Log.debug("🗑️ Deleted PQ deferred for key \(storageKey)", category: "MessageRouter")
            } else {
                _ = KeychainManager.shared.saveData(Data(rawBytes), forKey: storageKey)
                Log.debug("💾 Persisted PQ deferred for key \(storageKey)", category: "MessageRouter")
            }
        } else if key == "construct.orchestrator_state" {
            // Rust emits this after SessionHealNeeded / NeedSessionInit / EndSessionNeeded
            // to ensure the healing queue and pending queue survive app crashes.
            // Save the bytes directly rather than re-exporting (avoids a second FFI call).
            if rawBytes.isEmpty {
                Log.debug("⚠️ Orchestrator state save with empty data — ignoring", category: "MessageRouter")
            } else {
                _ = KeychainManager.shared.saveData(Data(rawBytes), forKey: "construct.orchestrator_state")
                Log.debug("💾 Orchestrator state persisted (\(rawBytes.count) bytes) via Rust action", category: "MessageRouter")
            }
        } else {
            Log.debug("🔷 Unhandled storage key: \(key)", category: "MessageRouter")
        }
    }

    private func handleResolvedMessage(
        _ decryptedContent: String,
        for message: ChatMessage,
        from otherUserId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        // Silently discard session establishment pings received on the normal message path.
        // These are sent after a tie-break win to trigger RESPONDER init on the peer.
        if decryptedContent.hasPrefix("__session_ping") && decryptedContent.hasSuffix("__") {
            Log.info("🏓 SESSION_STATE[ping_received_normal_path]: discarding session ping", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // Silently discard two-phase handshake confirmation signals.
        // __session_ready_<UUID>__ is sent by the RESPONDER after initReceivingSession succeeds.
        // Also handle legacy format without __ markers (older client versions).
        if decryptedContent.hasPrefix("__session_ready") || decryptedContent.hasPrefix("session_ready_") {
            Log.info("🤝 SESSION_STATE[session_ready_rust_path]: RESPONDER \(otherUserId.prefix(8))… confirmed session — discarding control message", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            // Mark session as confirmed so ChatViewModel stops buffering outgoing messages.
            SessionConfirmationTracker.shared.markConfirmed(otherUserId)
            // Flush messages that were buffered while waiting for RESPONDER confirmation.
            if let myId = SessionManager.shared.currentUserId {
                MessageRetryManager.shared.sendQueuedMessages(
                    for: chat,
                    recipientId: otherUserId,
                    currentUserId: myId,
                    context: context
                )
            }
            return
        }

        // 4. Check for special message types (profile sharing, etc.)
        if let specialMessageHandled = handleSpecialMessage(
            decryptedContent,
            from: otherUserId,
            in: context
        ), specialMessageHandled {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            return  // Special message handled, don't save as regular message
        }

        PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)

        // 5a. If this is an edit to an existing message — update it instead of saving a new one
        if !message.editsMessageId.isEmpty {
            let fetchRequest = Message.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", message.editsMessageId)
            fetchRequest.fetchLimit = 1
            if let original = try? context.fetch(fetchRequest).first {
                original.decryptedContent = decryptedContent
                original.isEdited = true
                original.editedAt = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                context.saveAndLog()
                Log.info("✏️ Edited message \(message.editsMessageId.prefix(8))…", category: "MessageRouter")
            } else {
                Log.error("❌ Cannot find original message to edit: \(message.editsMessageId)", category: "MessageRouter")
            }
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // 5. Save regular message
        saveMessage(for: chat, with: message, decryptedContent: decryptedContent, in: context)

        // 6. Acknowledge delivery to sender via stream
        onReceiptNeeded?([message.id], otherUserId, .delivered)

        // 7. Update chat metadata
        chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        context.saveAndLog()

        Log.info("📬 Message received and saved: \(message.id)", category: "MessageRouter")
    }
    
    // MARK: - Chat Management
    
    /// Find or create chat for user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: Tuple of (chat, isNewChat)
    private func findOrCreateChat(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> (Chat, Bool) {
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        if let existingChat = try? context.fetch(fetchRequest).first {
            return (existingChat, false)
        }
        
        // Create new user and chat
        let user = findOrCreateUser(for: userId, in: context)
        
        let newChat = Chat(context: context)
        newChat.id = UUID().uuidString
        newChat.otherUser = user
        
        return (newChat, true)
    }
    
    /// Find or create user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: User entity
    private func findOrCreateUser(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> User {
        let userFetchRequest = User.fetchRequest()
        let userIdPredicate = NSPredicate(format: "id == %@", userId)
        var predicates: [NSPredicate] = [userIdPredicate]
        if let existingPredicate = userFetchRequest.predicate {
            predicates.insert(existingPredicate, at: 0)
        }
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        if let existingUser = try? context.fetch(userFetchRequest).first {
            Log.debug("Using existing user: id=\(userId)", category: "MessageRouter")
            return existingUser
        }
        
        // Create new user with temporary username (will be updated from publicKeyBundle)
        let newUser = User(context: context)
        newUser.id = userId
        newUser.username = ""
        newUser.displayName = DisplayNameGenerator.generate(from: userId)
        newUser.isSharingWithMe = false
        newUser.isBlocked = false
        newUser.amISharingWith = false
        newUser.isContact = true
        newUser.addedAt = Date()
        
        Log.debug("Created new user: id=\(userId)", category: "MessageRouter")
        return newUser
    }
    
    // MARK: - First Message Handling
    
    /// Handle first message from user (no session yet)
    private func handleFirstMessage(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        isNewChat: Bool,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        let isFirstForUser = pendingMessages[userId] == nil || pendingMessages[userId]!.isEmpty

        // Deduplicate: skip if same message ID is already in the queue
        if pendingMessages[userId]?.contains(where: { $0.id == message.id }) == true {
            Log.debug("⏭️ Skipping duplicate queued message \(message.id.prefix(8))...", category: "MessageRouter")
            // Do NOT ACK as delivered yet: session init may still fail, and acknowledging would
            // cause the server to drop the pending message even though we haven't decrypted it.
            return
        }

        // Guard: initReceivingSession requires messageNumber=0 (X3DH handshake).
        // If we have no session and the message is already mid-ratchet, we can never
        // initialize from it — request the sender to restart their session instead.
        if message.messageNumber > 0 && isFirstForUser {
            Log.info("⚠️ No session for \(userId.prefix(8)) but messageNumber=\(message.messageNumber) — requesting END_SESSION so sender restarts", category: "MessageRouter")
            // Mark as processed + send failed receipt so server removes it from pending queue.
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            onReceiptNeeded?([message.id], userId, .failed)
            // Initialize the pending queue so subsequent out-of-sync messages from the same
            // user don't each spawn a new system message (isFirstForUser would stay true
            // otherwise since we return early without ever adding to pendingMessages).
            pendingMessages[userId] = []
            addSystemMessage(
                "Encrypted session out of sync. Asking contact to restart...",
                toUserId: userId,
                in: context
            )
            if isNewChat { context.delete(chat) }
            onEndSessionNeeded?(userId)
            return
        }

        // Cap per-user queue to prevent unbounded memory growth during prolonged
        // session-init failures. Unqueued messages stay on the server and will be
        // re-delivered once the session is established and the queue drains.
        let maxPendingPerUser = 100
        if (pendingMessages[userId]?.count ?? 0) >= maxPendingPerUser {
            Log.info("⚠️ Pending queue saturated for \(userId.prefix(8))… (\(maxPendingPerUser) messages) — not queueing until session init completes", category: "MessageRouter")
            return
        }

        // Append to the queue (do NOT overwrite — we need message_number=0 for session init)
        pendingMessages[userId, default: []].append(message)

        Log.info("📩 Message queued for session init from \(userId) — queue size: \(pendingMessages[userId]!.count)", category: "MessageRouter")
        Log.info("🔐 SESSION_STATE[first_message]: userId=\(userId.prefix(8))..., messageNumber=\(message.messageNumber), action=\(isFirstForUser ? "fetch_bundle" : "queued")", category: "SessionInit")

        // If we created a new chat, save it so it appears in UI
        if isNewChat {
            do {
                try context.save()
                Log.debug("✅ Saved new chat for \(userId)", category: "MessageRouter")
                onChatCreated?(chat)
            } catch {
                Log.error("❌ Failed to save new chat: \(error)", category: "MessageRouter")
            }
        }

        // Request bundle only once (on the first message; subsequent messages just queue)
        if isFirstForUser {
            onPublicKeyBundleNeeded?(userId, message)
        }
    }
    
    // MARK: - Session Message Handling
    
    /// Handle message when session exists
    /// - Returns: Decrypted content or nil if failed
    private func handleMessageWithSession(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) -> String? {
        Log.info("🔐 SESSION_STATE[decrypt_attempt]: userId=\(userId.prefix(8))..., hasSession=true", category: "SessionInit")
        
        guard let content = try? CryptoManager.shared.decryptMessage(message) else {
            Log.error("❌ Failed to decrypt incoming message \(message.id)", category: "MessageRouter")
            Log.error("🔐 SESSION_STATE[decrypt_failed]: userId=\(userId.prefix(8))..., messageId=\(message.id.prefix(8))..., messageNumber=\(message.messageNumber)", category: "SessionInit")

            // A genuine X3DH re-init must have at least one of:
            //   kemCiphertext.count > 0  → PQXDH (Kyber ciphertext is included)
            //   oneTimePreKeyId > 0      → classic X3DH with a one-time prekey
            // msgNum=0 alone is insufficient: it also occurs at DR ratchet epoch boundaries
            // (new DH ratchet step resets the sending chain counter to 0). Attempting
            // initReceivingSession in that case derives a completely wrong root key and
            // deepens the divergence. When neither signal is present we fall through to
            // heal_impossible, which sends END_SESSION and forces a clean re-handshake.
            let isLikelyX3DHInit = message.kemCiphertext.count > 0 || message.oneTimePreKeyId > 0
            if SessionHealingService.shared.canHeal(message) && isLikelyX3DHInit {
                // messageNumber == 0 → X3DH re-init from sender (classic or PQXDH).
                // Session was already archived by decryptMessage (reason: decryptionFailed).
                //
                // Tie-break: if BOTH sides re-inited as INITIATOR simultaneously, we must pick
                // exactly one side to win. Lower userId = INITIATOR. Higher userId = RESPONDER.
                // The winner restores its just-archived INITIATOR session; the loser heals.
                let myUserId = SessionManager.shared.currentUserId ?? ""
                let suiteIdBeforeTieBreak = UserDefaults.standard.integer(forKey: "construct.session.suite.\(userId)")
                let tieBreakRole = (!myUserId.isEmpty && myUserId < userId) ? "INITIATOR" : "RESPONDER"
                Log.info("⚖️ SESSION_STATE[tie_break_decision]: my=\(myUserId.prefix(8))… vs peer=\(userId.prefix(8))… → role=\(tieBreakRole), suiteId_current=\(suiteIdBeforeTieBreak), kemCt=\(message.kemCiphertext.count)b, otpkId=\(message.oneTimePreKeyId)", category: "SessionInit")
                if !myUserId.isEmpty && myUserId < userId {
                    // We're lower userId → we are the INITIATOR. Try to restore our
                    // just-archived session so we keep the INITIATOR role.
                    let restored = CryptoManager.shared.restoreLatestArchive(for: userId)
                    if restored {
                        let suiteIdAfterRestore = UserDefaults.standard.integer(forKey: "construct.session.suite.\(userId)")
                        Log.info("🏆 SESSION_STATE[tie_break_win]: kept INITIATOR (lower userId), ACKed X3DH from \(userId.prefix(8))…, suiteId_restored=\(suiteIdAfterRestore)", category: "SessionInit")
                        PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                        onReceiptNeeded?([message.id], userId, .delivered)
                        // Send END_SESSION to stop the loser's invalid message stream, then send a
                        // session establishment ping so the loser can immediately become RESPONDER.
                        onTieBreakWin?(userId)
                    } else {
                        // Archive missing or corrupt — can't restore INITIATOR role.
                        // Fall through to RESPONDER heal instead of silently losing the message.
                        Log.info("⚠️ SESSION_STATE[tie_break_fallback]: no archive to restore for \(userId.prefix(8))… — healing as RESPONDER instead", category: "SessionInit")
                        SessionHealingService.shared.enqueue(message, in: context)
                        pendingMessages[userId, default: []].append(message)
                        onSessionHealNeeded?(userId, message)
                    }
                } else {
                    // We're higher userId → become RESPONDER and heal from their X3DH init.
                    Log.info("🩹 SESSION_STATE[heal_triggered]: msgNum=0, kemCiphertext=\(message.kemCiphertext.count)b from \(userId.prefix(8))… — healing (tie-break: we are RESPONDER)", category: "SessionInit")
                    SessionHealingService.shared.enqueue(message, in: context)
                    pendingMessages[userId, default: []].append(message)
                    onSessionHealNeeded?(userId, message)
                }
            } else {
                // DR ratchet diverged (messageNumber > 0), OR msgNum=0 with no X3DH init signals
                // (kemCiphertext=0 + oneTimePreKeyId=0 → ambiguous, treated as diverged DR epoch).
                // Send FAILED receipt: server automatically relays SESSION_RESET to sender (server-side item 12).
                // Also send explicit END_SESSION message for defense-in-depth (sender handles both idempotently).
                Log.info("🔄 SESSION_STATE[heal_impossible]: messageNumber=\(message.messageNumber), kemCt=\(message.kemCiphertext.count)b, otpkId=\(message.oneTimePreKeyId) — ratchet diverged, requesting END_SESSION", category: "SessionInit")
                onReceiptNeeded?([message.id], userId, .failed)
                pendingMessages.removeValue(forKey: userId)
                SessionHealingService.shared.clearQueue(for: userId, in: context)
                onEndSessionNeeded?(userId)
            }

            return nil
        }

        // Check if username is still UUID - request update if needed
        checkUsernameUpdate(for: userId, chat: chat, in: context)

        return content
    }
    
    /// Check if username needs updating
    private func checkUsernameUpdate(
        for userId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        guard let user = chat.otherUser else { return }
        
        let usernameIsGuid = user.username == user.id || user.username == userId
        let displayNameIsGuid = user.displayName == user.id || user.displayName == userId
        
        if usernameIsGuid || displayNameIsGuid {
            Log.info("🔄 Username for \(userId) is still UUID, requesting update", category: "MessageRouter")
            onUsernameUpdateNeeded?(userId)
        }
    }
    
    // MARK: - Special Message Types
    
    /// Handle special message types (profile, etc.)
    /// - Returns: true if special message was handled
    private func handleSpecialMessage(
        _ decryptedContent: String,
        from userId: String,
        in context: NSManagedObjectContext
    ) -> Bool? {
        // Check for profile message
        if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let jsonData = decryptedContent.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            
            if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) {
                Log.info("📥 Received profile message from \(userId)", category: "MessageRouter")
                ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId, in: context)
                return true
            } else {
                Log.info("⚠️ Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                return true  // Still skip saving as regular message
            }
        }
        
        return false  // Not a special message
    }
    
    // MARK: - END_SESSION Handling

    /// Handle END_SESSION message.
    ///
    /// Primary path: delegate archiving to Rust via `handleEventJson` so the
    /// archive format is canonical and owned by the Rust orchestrator.
    /// Fallback: if the Rust path fails (e.g., no active session), use the
    /// existing Swift `archiveSession` to preserve existing behaviour.
    private func handleEndSession(
        from userId: String,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        Log.info("🛑 Handling END_SESSION from \(userId)", category: "MessageRouter")

        // 1. Archive the session — prefer Rust-owned archiving.
        var rustHandled = false
        if let core = CryptoManager.shared.orchestratorCore {
            let endSessionData = Data("__END_SESSION__".utf8)
            let event = CfeIncomingEvent.messageReceived(
                messageId: "end_session_\(userId)_\(Int(Date().timeIntervalSince1970))",
                from: userId,
                data: endSessionData,
                msgNum: 0,
                kemCt: Data(),
                otpkId: 0,
                isControl: true,
                contentType: 0
            )
            if let actions = try? core.handleEvent(event: event) {
                executeStorageActions(actions)
                rustHandled = true
                Log.debug("✅ END_SESSION: session archived via Rust orchestrator for \(userId.prefix(8))…", category: "MessageRouter")
            } else {
                Log.debug("⚠️ END_SESSION: Rust handleEvent failed for \(userId.prefix(8))… — falling back to Swift archive", category: "MessageRouter")
            }
        }

        if !rustHandled {
            CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
            Log.debug("✅ END_SESSION: session archived via Swift fallback for \(userId.prefix(8))…", category: "MessageRouter")
        }

        // 2. Re-queue any outgoing messages that were sent to the server but not yet
        //    delivered (no ACK). These were encrypted with the now-archived session keys
        //    and cannot be decrypted by the peer under the new session — so they must be
        //    re-encrypted and re-sent once the new session is established.
        requeueUndeliveredOutgoing(for: userId, in: context)

        // 3. Remove any pending *incoming* messages and healing queue for this user
        pendingMessages.removeValue(forKey: userId)
        SessionHealingService.shared.clearQueue(for: userId, in: context)

        // 4. Notify coordinator so the natural INITIATOR can prewarm immediately.
        onEndSessionReceived?(userId)

        Log.info("✅ END_SESSION handled for \(userId)", category: "MessageRouter")
    }
    
    /// Marks outgoing messages that were sent to the server but never delivered as `.queued`,
    /// so they can be re-encrypted and re-sent under the fresh session after END_SESSION.
    /// Only considers messages sent in the past `requeueWindowSeconds` to avoid re-sending stale chat.
    private func requeueUndeliveredOutgoing(
        for userId: String,
        in context: NSManagedObjectContext,
        requeueWindowSeconds: TimeInterval = 300
    ) {
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)
        guard let chat = (try? context.fetch(chatFetch))?.first else { return }

        let since = Date().addingTimeInterval(-requeueWindowSeconds)
        let msgFetch = Message.fetchRequest()
        msgFetch.predicate = NSPredicate(
            format: "chat == %@ AND isSentByMe == YES AND deliveryStatusRaw == %d AND timestamp >= %@",
            chat,
            DeliveryStatus.sent.rawValue,
            since as NSDate
        )
        msgFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        guard let messages = try? context.fetch(msgFetch), !messages.isEmpty else { return }

        for msg in messages {
            msg.deliveryStatus = .queued
        }
        context.saveAndLog()

        Log.info("♻️ END_SESSION: re-queued \(messages.count) sent-but-undelivered message(s) for \(userId.prefix(8))… — will resend under new session", category: "MessageRouter")
    }

    /// Add a system message to chat
    private func addSystemMessage(
        _ text: String,
        toUserId userId: String,
        in context: NSManagedObjectContext
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        // Find chat
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        guard let chat = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Cannot add system message: chat not found for \(userId)", category: "MessageRouter")
            return
        }
        
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.chat = chat
        message.fromUserId = "SYSTEM"
        message.toUserId = currentUserId
        message.encryptedContent = ""
        message.decryptedContent = text
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        
        chat.lastMessageText = Chat.formatPreviewText(text)
        chat.lastMessageTime = Date()
        
        do {
            try context.save()
            Log.debug("✅ System message added to chat with \(userId)", category: "MessageRouter")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "MessageRouter")
        }
    }
    
    // MARK: - Message Persistence
    
    /// Save message to Core Data
    private func saveMessage(
        for chat: Chat,
        with messageData: ChatMessage,
        decryptedContent: String,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id ==[c] %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        // Check if message already exists (from background fetch)
        if let existingMessage = try? context.fetch(fetchRequest).first {
            // Update decryptedContent if it's nil
            if existingMessage.decryptedContent == nil {
                Log.debug("🔄 Updating decrypted content for message \(messageData.id)", category: "MessageRouter")
                existingMessage.decryptedContent = decryptedContent
                
                do {
                    try context.save()
                    Log.debug("✅ Updated message decryption", category: "MessageRouter")
                } catch {
                    Log.error("❌ Failed to update message: \(error)", category: "MessageRouter")
                }
            }
            return  // Message already exists
        }
        
        // Create new message
        let message = Message(context: context)
        message.id = messageData.id.lowercased()
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.encryptedContent = messageData.content
        message.decryptedContent = decryptedContent
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        // Restore reply-to context so the receiver sees the same reply bubble as the sender.
        if !messageData.replyToMessageId.isEmpty {
            message.replyToMessageId = messageData.replyToMessageId.lowercased()
            // Look up the replied-to message locally to populate the preview snippet.
            let replyFetch = Message.fetchRequest()
            replyFetch.predicate = NSPredicate(format: "id ==[c] %@", messageData.replyToMessageId)
            replyFetch.fetchLimit = 1
            if let replyMsg = (try? context.fetch(replyFetch))?.first {
                message.replyToContent = replyMsg.decryptedContent
            }
        }
        
        do {
            try context.save()
            PerformanceMetrics.shared.messageUIDisplayed(messageId: messageData.id)

            let senderId = messageData.from

            // ── Incoming flood check ────────────────────────────────────────────
            let floodResult = IncomingFloodGuard.shared.check(senderId: senderId)

            // ── Lockdown check ──────────────────────────────────────────────────
            let lockdownSuppressed = LockdownManager.shared.shouldSuppress(senderId: senderId)

            // Decide whether to show notification
            let chatId    = chat.id
            let isMuted   = chat.isMuted
            let senderName = (chat.otherUser?.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
                                .flatMap { $0.isEmpty ? nil : $0 }
                            ?? chat.otherUser?.username
                            ?? "Unknown"
            let preview   = Chat.formatPreviewText(decryptedContent)

            switch floodResult {
            case .burstDetected(let count):
                // First burst event — post a single special system notification instead
                // of the regular message preview. Subsequent messages are silently dropped
                // from notifications until the user reviews.
                Log.info("🚨 Burst detected: \(count) msgs/30s from \(senderId.prefix(8))…", category: "FloodGuard")
                if !isMuted {
                    InAppNotificationService.shared.handleFloodAlert(
                        chatId: chatId,
                        senderName: senderName,
                        messageCount: count
                    )
                }

            case .alreadySuppressed:
                // Silently save; no notification
                Log.debug("🔇 Suppressed notification from flooder \(senderId.prefix(8))…", category: "FloodGuard")

            case .normal:
                if lockdownSuppressed {
                    Log.debug("🔒 Lockdown: suppressed notification from new sender \(senderId.prefix(8))…", category: "LockdownManager")
                } else if !isMuted {
                    InAppNotificationService.shared.handle(
                        chatId: chatId,
                        isMuted: false,
                        senderName: senderName,
                        preview: preview
                    )
                }
            }
        } catch {
            Log.error("❌ Failed to save message: \(error)", category: "MessageRouter")
        }
    }

    // MARK: - SENDER_SYNC Handling

    /// Handle an incoming SENDER_SYNC message — a copy of an outgoing message sent by
    /// the user's own other device. Decrypts using the per-device session and saves
    /// the message as an outgoing bubble in the correct conversation.
    private func handleSenderSync(_ message: ChatMessage, in context: NSManagedObjectContext) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }

        let partnerUserId = extractPartnerUserId(from: message.conversationId, myUserId: currentUserId)
        guard !partnerUserId.isEmpty else {
            Log.error("❌ SENDER_SYNC: cannot extract partner from conversationId='\(message.conversationId)'", category: "MessageRouter")
            return
        }

        let contactId = message.senderDeviceId.isEmpty
            ? message.from
            : MultiDeviceSendCoordinator.sessionKey(userId: message.from, deviceId: message.senderDeviceId)

        let hasSession = CryptoManager.shared.hasSession(for: contactId)

        if hasSession {
            guard let decrypted = try? CryptoManager.shared.decryptMessage(message, contactIdOverride: contactId) else {
                Log.error("❌ SENDER_SYNC: decryption failed for contactId=\(contactId.prefix(20))…", category: "MessageRouter")
                return
            }
            saveSenderSyncMessage(decrypted, original: message, partnerUserId: partnerUserId, in: context)
        } else if message.messageNumber == 0 {
            // New device: init receiving session async, then save
            guard !message.senderDeviceId.isEmpty else {
                Log.error("❌ SENDER_SYNC: no senderDeviceId for first message — cannot init session", category: "MessageRouter")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.initAndDecryptSenderSync(
                    message: message,
                    contactId: contactId,
                    partnerUserId: partnerUserId,
                    in: context
                )
            }
        } else {
            Log.error("❌ SENDER_SYNC: no session for \(contactId.prefix(20))… and messageNumber=\(message.messageNumber) > 0 — dropping", category: "MessageRouter")
        }
    }

    /// Extract the OTHER user's ID from a direct conversation ID.
    /// Format: "direct:{sorted_user1}:{sorted_user2}"
    private func extractPartnerUserId(from conversationId: String, myUserId: String) -> String {
        let parts = conversationId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "direct" else { return "" }
        let a = String(parts[1]), b = String(parts[2])
        if a == myUserId { return b }
        if b == myUserId { return a }
        return ""
    }

    /// Save a decrypted SENDER_SYNC message as an outgoing bubble.
    private func saveSenderSyncMessage(
        _ decrypted: String,
        original: ChatMessage,
        partnerUserId: String,
        in context: NSManagedObjectContext
    ) {
        let (chat, _) = findOrCreateChat(for: partnerUserId, in: context)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", original.id)
        fetch.fetchLimit = 1
        if (try? context.fetch(fetch))?.first != nil {
            return // already saved (duplicate delivery)
        }

        let msg = Message(context: context)
        msg.id = original.id
        msg.fromUserId = original.from
        msg.toUserId = partnerUserId
        msg.encryptedContent = original.content
        msg.decryptedContent = decrypted
        msg.timestamp = Date(timeIntervalSince1970: TimeInterval(original.timestamp))
        msg.isSentByMe = true
        msg.deliveryStatus = .sent
        msg.retryCount = 0
        msg.chat = chat

        chat.lastMessageText = Chat.formatPreviewText(decrypted)
        chat.lastMessageTime = msg.timestamp
        context.saveAndLog()

        if !original.senderDeviceId.isEmpty {
            CryptoManager.shared.saveSessionToKeychainPublic(
                for: MultiDeviceSendCoordinator.sessionKey(userId: original.from, deviceId: original.senderDeviceId)
            )
        }
        Log.info("✅ SENDER_SYNC: saved outgoing message in conversation with \(partnerUserId.prefix(8))…", category: "MessageRouter")
    }

    /// Async helper: fetch sender device bundle, init receiving session, then save.
    private func initAndDecryptSenderSync(
        message: ChatMessage,
        contactId: String,
        partnerUserId: String,
        in context: NSManagedObjectContext
    ) async {
        do {
            let bundle = try await KeyServiceClient.shared.getPreKeyBundle(
                userId: message.from,
                deviceId: message.senderDeviceId
            )
            let bundleWithSuite = (
                identityPublic: bundle.identityPublic,
                signedPrekeyPublic: bundle.signedPrekeyPublic,
                signature: bundle.signature,
                verifyingKey: bundle.verifyingKey,
                suiteId: "1"
            )
            let decrypted = try CryptoManager.shared.initReceivingSession(
                for: contactId,
                recipientBundle: bundleWithSuite,
                firstMessage: message
            )
            saveSenderSyncMessage(decrypted, original: message, partnerUserId: partnerUserId, in: context)

            // Replenish any OTPKs consumed during this session init
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
        } catch {
            Log.error("❌ SENDER_SYNC: initReceivingSession failed for \(contactId.prefix(20))…: \(error)", category: "MessageRouter")
        }
    }
}
