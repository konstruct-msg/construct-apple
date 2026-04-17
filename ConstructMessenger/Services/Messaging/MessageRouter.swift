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

    static let shared = MessageRouter()
    
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
    /// Receiver should re-initiate if it is the natural INITIATOR (higher deviceId).
    var onEndSessionReceived: ((String, UInt64) -> Void)?

    /// Returns `true` if an END_SESSION from the given peer with the given server timestamp
    /// should be discarded because it predates the currently-established session.
    /// Set by SessionCoordinator; nil means "never stale" (safe default).
    var isEndSessionStale: ((String, UInt64) -> Bool)?

    /// Called when an existing session failed to decrypt a `messageNumber==0` message.
    /// The remote peer re-keyed — caller should archive the current session and
    /// attempt `initReceivingSession` with the supplied message as the new X3DH init.
    var onSessionHealNeeded: ((String, ChatMessage) -> Void)?

    /// Called when this device wins the tie-break (higher deviceId restores INITIATOR session).
    /// Receiver should send END_SESSION to the loser and then send a session establishment
    /// ping so the loser can immediately become RESPONDER without user action.
    var onTieBreakWin: ((String) -> Void)?

    /// Called when a receipt should be sent via the stream.
    /// Provides message IDs, the original sender's user ID (for server routing), and receipt status.
    var onReceiptNeeded: (([String], String, Shared_Proto_Signaling_V1_ReceiptStatus) -> Void)?

    private let chunkReassembler = ChunkedMessageReassembler.shared

    // MARK: - Rust Timer Support (R-C2)
    // When Rust emits scheduleTimer, Swift must fire timerFired after the given delay.
    // Keys are timerId strings; values are in-flight Task handles for cancellation.
    private var rustTimers: [String: Task<Void, Never>] = [:]
    private let rustTimersLock = NSLock()

    /// Schedule (or reschedule) a Rust-requested timer. Fires `timerFired` to the orchestrator after `delayMs`.
    func scheduleRustTimer(timerId: String, delayMs: UInt64) {
        cancelRustTimer(timerId: timerId)
        let task = Task { @MainActor [weak self] in
            let ns = UInt64(delayMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, let self else { return }
            let event = CfeIncomingEvent.timerFired(timerId: timerId)
            if let actions = try? CryptoManager.shared.handleOrchestratorEvent(event, tag: "rust_timer"), !actions.isEmpty {
                self.executeRustTimerActions(actions)
            }
            _ = self.rustTimersLock.withLock { self.rustTimers.removeValue(forKey: timerId) }
        }
        rustTimersLock.withLock { rustTimers[timerId] = task }
        Log.debug("⏲ Rust timer scheduled: \(timerId) in \(delayMs)ms", category: "MessageRouter")
    }

    /// Cancel a pending Rust-requested timer.
    func cancelRustTimer(timerId: String) {
        rustTimersLock.withLock {
            if let existing = rustTimers.removeValue(forKey: timerId) {
                existing.cancel()
                Log.debug("⏲ Rust timer cancelled: \(timerId)", category: "MessageRouter")
            }
        }
    }

    /// Execute actions returned after a timerFired event (heal retries etc.).
    private func executeRustTimerActions(_ actions: [CfeAction]) {
        for action in actions {
            switch action {
            case .scheduleTimer(let id, let delay):
                scheduleRustTimer(timerId: id, delayMs: delay)
            case .cancelTimer(let id):
                cancelRustTimer(timerId: id)
            case .notifyError(let code, let msg):
                Log.error("❌ Rust timer action error [\(code)]: \(msg)", category: "MessageRouter")
            default:
                // Route storage actions through the storage pipeline; log others.
                if case .saveSessionToSecureStore = action {
                    executeStorageActions([action])
                } else {
                    Log.debug("🔷 Unhandled Rust timer action: \(action)", category: "MessageRouter")
                }
            }
        }
    }

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

        // STEALTH: resolve sender from sealed inner before any routing.
        // `from` is empty for ConstructSEALED messages — decrypt to recover sender ID.
        var message = message
        if message.from.isEmpty && !message.sealedInnerData.isEmpty {
            if let senderId = StealthSenderService.shared.resolveSender(sealedInnerBytes: message.sealedInnerData) {
                message = ChatMessage(
                    id: message.id,
                    from: senderId,
                    to: message.to.isEmpty ? currentUserId : message.to,
                    messageType: message.messageType,
                    ephemeralPublicKey: message.ephemeralPublicKey,
                    messageNumber: message.messageNumber,
                    content: message.content,
                    suiteId: message.suiteId,
                    timestamp: message.timestamp,
                    oneTimePreKeyId: message.oneTimePreKeyId,
                    editsMessageId: message.editsMessageId,
                    kemCiphertext: message.kemCiphertext,
                    contentType: message.contentType,
                    kyberOtpkId: message.kyberOtpkId,
                    senderDeviceId: message.senderDeviceId,
                    conversationId: message.conversationId,
                    replyToMessageId: message.replyToMessageId,
                    rawPayload: message.rawPayload
                    // sealedInnerData intentionally omitted — sender resolved
                )
                Log.debug("🕶️ STEALTH: resolved sender → \(senderId.prefix(8))…", category: "MessageRouter")
            } else {
                Log.error("❌ STEALTH: could not resolve sender for message \(message.id.prefix(8))… — dropping", category: "MessageRouter")
                return
            }
        }

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
        Log.debug("   content (padded): \(message.content.count) bytes", category: "MessageRouter")
        let contentPreview = message.content.prefix(16).map { String(format: "%02x", $0) }.joined()
        Log.debug("   content preview: \(contentPreview)…", category: "MessageRouter")
        Log.debug("   isEndSession: \(message.isEndSession)", category: "MessageRouter")
        if !message.editsMessageId.isEmpty {
            Log.debug("   editsMessageId: \(message.editsMessageId)", category: "MessageRouter")
        }
        #endif
        
        // 1. Skip if already processed — applies to ALL messages including END_SESSION.
        //    Without this, the same END_SESSION is processed twice (pending queue + stream).
        //
        //    Exception: if this is a session init (msgNum=0) and we have no active session
        //    for the sender, re-process it. This handles the crash-recovery scenario where
        //    the init was ACKed before the session was persisted (e.g., app crashed mid-init).
        if PersistentACKStore.shared.isProcessed(message.id, in: context) {
            let isOrphanedInit = message.messageNumber == 0
                && !message.isEndSession
                && !message.isSenderSync
                && !CryptoManager.shared.hasSession(for: otherUserId)
            if !isOrphanedInit {
                Log.debug("⏭️ Skipping already-processed message \(message.id.prefix(8))… (ACK store)", category: "MessageRouter")
                onReceiptNeeded?([message.id], otherUserId, .delivered)
                return
            }
            Log.info("🔄 Re-processing orphaned session init \(message.id.prefix(8))… (no active session for \(otherUserId.prefix(8))…)", category: "MessageRouter")
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

        // 3a. SESSION_RESET_INIT: atomic archive of old session + RESPONDER init in one step.
        //     Must be checked BEFORE the END_SESSION path (it carries a real X3DH payload).
        if message.isSessionResetInit {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.info("🔄 SESSION_RESET_INIT from \(otherUserId.prefix(8))…", category: "MessageRouter")
            handleSessionResetInit(message: message, from: otherUserId, in: context, pendingMessages: &pendingMessages)
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // 3. Check if this is an END_SESSION control message
        if message.isEndSession {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.info("🛑 Received END_SESSION from \(otherUserId)", category: "MessageRouter")
            handleEndSession(from: otherUserId, messageTimestamp: message.timestamp, in: context, pendingMessages: &pendingMessages)
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
        }

        // Guard: after a tie-break WIN we sent SESSION_RESET_INIT and are waiting for the
        // RESPONDER (peer) to acknowledge. Any msgNum=0 arriving in this window is from
        // the peer's OLD init attempt (different ephemeral keys) and will always fail AEAD.
        // ACK and discard it rather than letting the Rust core produce sendEndSession → loop.
        if message.messageNumber == 0
            && !message.isEndSession
            && !message.isSessionResetInit
            && SessionConfirmationTracker.shared.isPending(otherUserId) {
            Log.info("🔇 SESSION_STATE[stale_init_drop]: discarding stale msgNum=0 from \(otherUserId.prefix(8))… (tie-break WIN, pending RESPONDER confirm)", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            if isNewChat { context.delete(chat) }
            return
        }

        // Rust orchestrator is the SINGLE decrypt path — no Swift fallback.
        // Изъян 4: If orchestratorCore is nil (e.g. Keychain locked after reboot),
        // attempt a one-shot reload before giving up and triggering END_SESSION.
        if CryptoManager.shared.orchestratorCore == nil {
            Log.info("⚠️ OrchestratorCore nil — attempting reload before END_SESSION", category: "MessageRouter")
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        guard CryptoManager.shared.orchestratorCore != nil else {
            Log.error("❌ OrchestratorCore still nil after reload — requesting END_SESSION from \(otherUserId.prefix(8))…", category: "MessageRouter")
            onEndSessionNeeded?(otherUserId)
            if isNewChat { context.delete(chat) }
            return
        }
        guard let event = buildIncomingEvent(message: message, otherUserId: otherUserId) else {
            Log.error("❌ Cannot build incoming event for \(message.id.prefix(8))… — skipping", category: "MessageRouter")
            if isNewChat { context.delete(chat) }
            return
        }

        var actions: [CfeAction]
        do {
            PerformanceMetrics.shared.messageDecryptStart(messageId: message.id)
            actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "incoming_message")
            PerformanceMetrics.shared.messageDecryptEnd(messageId: message.id)
        } catch {
            Log.error("❌ handleEvent threw for \(message.id.prefix(8))…: \(error) — sending END_SESSION", category: "MessageRouter")
            onEndSessionNeeded?(otherUserId)
            if isNewChat { context.delete(chat) }
            return
        }

        // Handle checkAckInDb round-trip synchronously (Rust ACK cache miss after restart).
        // Rust returns [checkAckInDb(id)] when its in-memory cache misses; Swift checks Core Data
        // and feeds back ackDbResult so Rust can decide whether to decrypt or drop the message.
        if actions.count == 1, case .checkAckInDb(let ackMsgId) = actions[0] {
            let isProcessed = PersistentACKStore.shared.isProcessed(ackMsgId, in: context)
            let ackResult = CfeIncomingEvent.ackDbResult(messageId: ackMsgId, isProcessed: isProcessed)
            if let followup = try? CryptoManager.shared.handleOrchestratorEvent(ackResult, tag: "ack_db_result"), !followup.isEmpty {
                actions = followup
            }
        }

        for action in actions {
            switch action {
            case .messageDecrypted:
                executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
                return
            case .sessionHealNeeded(let contactId, let role):
                handleRustHealDecision(role: role, contactId: contactId, message: message, in: context, pendingMessages: &pendingMessages)
                if isNewChat { context.delete(chat) }
                return
            case .sendEndSession(let contactId):
                Log.info("🔄 SESSION_STATE[rust_end_session]: DR diverged for \(contactId.prefix(8))… — sending END_SESSION", category: "SessionInit")
                onReceiptNeeded?([message.id], contactId, .failed)
                pendingMessages.removeValue(forKey: contactId)
                SessionHealingService.shared.clearQueue(for: contactId, in: context)
                onEndSessionNeeded?(contactId)
                if isNewChat { context.delete(chat) }
                return
            case .fetchPublicKeyBundle(let userId):
                Log.info("⚠️ SESSION_STATE[rust_session_lost]: re-queuing \(message.id.prefix(8))… for \(userId.prefix(8))…", category: "SessionInit")
                pendingMessages[userId, default: []].append(message)
                onPublicKeyBundleNeeded?(userId, message)
                return
            default:
                break
            }
        }

        // No actionable routing decision (e.g. duplicate, cooldown) — ACK and skip.
        Log.debug("⚠️ handleEvent produced no routing decision for \(message.id.prefix(8))… — ACKing as delivered", category: "MessageRouter")
        onReceiptNeeded?([message.id], otherUserId, .delivered)
        if isNewChat { context.delete(chat) }
        return
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
        let sealedBox = MessagePadding.unpadCiphertext(message.content)
        guard sealedBox.count >= 12 else {
            Log.error("❌ buildIncomingEventLegacy: sealed box too short (\(sealedBox.count)b) for \(message.id.prefix(8))…", category: "MessageRouter")
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
            "suite_id": Int(message.suiteId)
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
                _ = contactId.isEmpty ? otherUserId : contactId
                checkUsernameUpdate(for: otherUserId, chat: chat, in: context)
                switch chunkReassembler.process(data: plaintext) {
                case .assembled(let text, let quoted):
                    handleResolvedMessage(text, quotedMessage: quoted, for: message, from: otherUserId, chat: chat, in: context)
                case .legacy(let text):
                    handleResolvedMessage(text, quotedMessage: nil, for: message, from: otherUserId, chat: chat, in: context)
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
                CryptoManager.shared.markAckProcessedInOrchestrator(messageId: messageId)

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

            case .checkAckInDb(let messageId):
                // Rust cache miss after restart — check Core Data and report back.
                Task { @MainActor in
                    let isProcessed = await PersistentACKStore.shared.isProcessed(messageId: messageId)
                    let result = CfeIncomingEvent.ackDbResult(messageId: messageId, isProcessed: isProcessed)
                    _ = try? CryptoManager.shared.handleOrchestratorEvent(result, tag: "ack_db_result_async")
                }

            case .healSuppressed(let contactId, let retryAfterMs):
                // Heal was rate-limited — do NOT ACK so server re-delivers after cooldown.
                Log.debug("⏳ Heal suppressed for \(contactId.prefix(8))… retry in \(retryAfterMs)ms", category: "MessageRouter")
                // Intentionally no ACK sent.

            case .sendHeartbeat(let contactId):
                // Изъян 7: heartbeat requested — send encrypted heartbeat payload to contact.
                Log.debug("💓 Sending heartbeat to \(contactId.prefix(8))…", category: "MessageRouter")
                Task { await MessageRouter.shared.sendSessionHeartbeat(to: contactId) }

            case .notifyLinkedDevicesOfSessionReset(let contactId):
                // Изъян 8: notify own linked devices that session with contactId was reset.
                Log.debug("📡 Notifying linked devices of session reset with \(contactId.prefix(8))…", category: "MessageRouter")
                Task { await MultiDeviceSendCoordinator.shared.broadcastSessionReset(contactId: contactId) }

            case .notifyError(let code, let msg):
                Log.error("❌ Rust orchestrator error [\(code)]: \(msg)", category: "MessageRouter")

            case .scheduleTimer(let timerId, let delayMs):
                scheduleRustTimer(timerId: timerId, delayMs: delayMs)

            case .cancelTimer(let timerId):
                cancelRustTimer(timerId: timerId)

            default:
                Log.debug("🔷 Unhandled Rust action in M5 path: \(action)", category: "MessageRouter")
            }
        }
    }

    /// Execute only storage actions from a typed Rust action list (no ChatMessage context needed).
    // MARK: - Outgoing Message Encryption via Rust Orchestrator

    /// Encrypt a plaintext message through the Rust orchestrator (single source of truth for DR).
    ///
    /// Returns binary WirePayload ready to pass as `encryptedPayload` in the gRPC `SendMessage` call.
    /// Persists updated DR session state as a side-effect.
    ///
    /// - Parameters:
    ///   - plaintext: Serialised plaintext bytes (protobuf MessageContent, binary KNST frame, or UTF-8).
    ///   - messageId: Unique message UUID (used for ACK tracking).
    ///   - recipientId: Contact user ID.
    ///   - contentType: Proto ContentType (0 = regular message, default).
    func encryptOutgoing(
        plaintext: Data,
        messageId: String,
        recipientId: String,
        contentType: UInt8 = 0
    ) throws -> Data {
        let event = CfeIncomingEvent.outgoingMessage(
            contactId: recipientId,
            messageId: messageId,
            plaintext: plaintext,
            contentType: contentType
        )
        let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "outgoing_message")
        executeStorageActions(actions)
        for action in actions {
            if case .sendEncryptedMessage(let to, let payload, _, _) = action, to == recipientId {
                return Data(payload)
            }
        }
        throw NSError(
            domain: "MessageRouter",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "Orchestrator returned no SendEncryptedMessage for \(recipientId.prefix(8))…"]
        )
    }

    /// Encrypt a session control message (e.g. session ping, END_SESSION) through the orchestrator.
    ///
    /// Identical to `encryptOutgoing` but marked separately for clarity in call sites.
    func encryptSessionControl(
        plaintext: String,
        messageId: String,
        recipientId: String
    ) throws -> Data {
        try encryptOutgoing(
            plaintext: Data(plaintext.utf8),
            messageId: messageId,
            recipientId: recipientId,
            contentType: 0
        )
    }

    /// Изъян 7 — session health heartbeat.
    ///
    /// Encrypts and sends a small heartbeat payload to `contactId` using content_type=13 (HEARTBEAT).
    /// The peer will attempt to decrypt it; a decrypt failure triggers proactive heal before
    /// the user sends their next real message.
    func sendSessionHeartbeat(to contactId: String) async {
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }
        guard CryptoManager.shared.hasSession(for: contactId) else {
            Log.debug("💓 Heartbeat skip for \(contactId.prefix(8))… — no active session", category: "MessageRouter")
            return
        }
        let heartbeatId = UUID().uuidString.lowercased()
        do {
            let payload = try encryptOutgoing(
                plaintext: Data("__heartbeat__".utf8),
                messageId: heartbeatId,
                recipientId: contactId,
                contentType: 13
            )
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: heartbeatId,
                recipientId: contactId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                encryptedPayload: payload,
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            Log.debug("💓 Heartbeat sent to \(contactId.prefix(8))…", category: "MessageRouter")
        } catch {
            Log.error("❌ Heartbeat failed to \(contactId.prefix(8))…: \(error.localizedDescription)", category: "MessageRouter")
        }
    }

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
                KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
                Log.debug("🗑️ Deleted hot session for \(contactId.prefix(8))… (Rust archive_session)", category: "MessageRouter")
                CryptoManager.shared.saveOrchestratorStateCFE()
            } else {
                // Rust already exported the session as CFE binary — use bytes directly.
                _ = KeychainManager.shared.saveSessionData(Data(rawBytes), for: contactId)
                CryptoManager.shared.saveOrchestratorStateCFE()
            }
        } else if key.hasPrefix("archive_") {
            let contactId = String(key.dropFirst("archive_".count))
            CryptoManager.shared.acceptRustSessionArchive(contactId: contactId, archiveBytes: rawBytes)
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
        quotedMessage: Shared_Proto_Messaging_V1_QuotedMessage?,
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
                original.applyStoredEncryption(plaintext: decryptedContent, contactId: otherUserId)
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
        saveMessage(for: chat, with: message, decryptedContent: decryptedContent, quotedMessage: quotedMessage, in: context)

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
    
    // MARK: - Rust Heal Decision

    /// Dispatch a `SessionHealNeeded` action returned by the Rust orchestrator.
    ///
    /// - `role == "Initiator"` (WE WIN): our session is intact (Rust DR rollback). ACK peer's
    ///   X3DH init and send END_SESSION + ping so they become RESPONDER.
    /// - `role == "Responder"` (WE LOSE): archive our desynchronised session so the peer (INITIATOR)
    ///   can establish a fresh one, then trigger the RESPONDER heal path.
    private func handleRustHealDecision(
        role: String,
        contactId: String,
        message: ChatMessage,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        let myUserId = SessionManager.shared.currentUserId ?? ""
        let suiteId = Int(KeychainManager.shared.loadSessionSuiteId(userId: contactId) ?? 0)

        if role == "Initiator" {
            // We are INITIATOR (higher deviceId) — WE WIN the tie-break.
            // The Rust session is already intact thanks to the DR snapshot/rollback.
            Log.info("🏆 SESSION_STATE[tie_break_win]: kept INITIATOR (my=\(myUserId.prefix(8))… > peer=\(contactId.prefix(8))…), suiteId=\(suiteId)", category: "SessionInit")
            PersistentACKStore.shared.markProcessed(message.id, senderId: contactId, in: context)
            onReceiptNeeded?([message.id], contactId, .delivered)
            onTieBreakWin?(contactId)
        } else {
            // We are RESPONDER (lower deviceId) — peer WINS. Archive our session and heal.
            guard SessionHealingService.shared.canHeal(message) else {
                Log.error("❌ SESSION_STATE[heal_limit_exceeded]: too many heal attempts for \(contactId.prefix(8))… — sending END_SESSION", category: "SessionInit")
                onReceiptNeeded?([message.id], contactId, .failed)
                onEndSessionNeeded?(contactId)
                return
            }
            Log.info("🩹 SESSION_STATE[heal_triggered]: becoming RESPONDER (my=\(myUserId.prefix(8))… < peer=\(contactId.prefix(8))…), suiteId=\(suiteId)", category: "SessionInit")
            CryptoManager.shared.archiveSession(for: contactId, reason: .manualReset)
            SessionHealingService.shared.enqueue(message, in: context)
            pendingMessages[contactId, default: []].append(message)
            onSessionHealNeeded?(contactId, message)
        }
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

    /// Handle SESSION_RESET_INIT — atomic archive of old session + RESPONDER init in a single pass.
    ///
    /// Replaces the two-step `END_SESSION` → 200 ms delay → `msgNum=0` sequence used in the
    /// tie-break WIN path. The INITIATOR sends one message with `CONTENT_TYPE_SESSION_RESET_INIT=24`
    /// whose payload is the X3DH init (`msgNum=0`). RESPONDER:
    /// 1. Archives the old session (same as `handleEndSession`)
    /// 2. Routes the X3DH payload through `handleFirstMessage` (normal RESPONDER init)
    private func handleSessionResetInit(
        message: ChatMessage,
        from userId: String,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        // 1. Archive old session via Rust orchestrator (canonical path); Swift fallback otherwise.
        var rustHandled = false
        if CryptoManager.shared.orchestratorCore != nil {
            let endSessionData = Data("__END_SESSION__".utf8)
            let event = CfeIncomingEvent.messageReceived(
                messageId: "sri_archive_\(userId)_\(Int(Date().timeIntervalSince1970))",
                from: userId,
                data: endSessionData,
                msgNum: 0,
                kemCt: Data(),
                otpkId: 0,
                isControl: true,
                contentType: 0
            )
            if let actions = try? CryptoManager.shared.handleOrchestratorEvent(event, tag: "sri_archive") {
                executeStorageActions(actions)
                rustHandled = true
            }
        }
        if !rustHandled {
            CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
        }

        // 2. Re-queue outgoing messages sent under the old session (cannot be decrypted by peer).
        requeueUndeliveredOutgoing(for: userId, in: context)

        // 3. Remove stale pending messages and clear heal queue.
        pendingMessages.removeValue(forKey: userId)
        SessionHealingService.shared.clearQueue(for: userId, in: context)

        // 4. Route the X3DH payload as a fresh msgNum=0 — triggers normal RESPONDER init path.
        let (chat, isNewChat) = findOrCreateChat(for: userId, in: context)
        handleFirstMessage(
            message,
            from: userId,
            chat: chat,
            isNewChat: isNewChat,
            in: context,
            pendingMessages: &pendingMessages
        )

        Log.info("✅ SESSION_RESET_INIT: old session archived, RESPONDER init triggered for \(userId.prefix(8))…", category: "MessageRouter")
    }

    /// Handle END_SESSION message.
    ///
    /// Primary path: delegate archiving to Rust via `handleEventJson` so the
    /// archive format is canonical and owned by the Rust orchestrator.
    /// Fallback: if the Rust path fails (e.g., no active session), use the
    /// existing Swift `archiveSession` to preserve existing behaviour.
    private func handleEndSession(
        from userId: String,
        messageTimestamp: UInt64,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        // Guard against stale END_SESSION messages: if the message's server timestamp
        // predates our current active session, it was queued from a previous session
        // cycle and re-delivered by the server. ACK it (already done) and stop here —
        // tearing down a healthy session based on a stale END_SESSION causes cascades.
        if isEndSessionStale?(userId, messageTimestamp) == true {
            Log.info("🗑️ Discarding stale END_SESSION from \(userId.prefix(8))… (ts=\(messageTimestamp))", category: "MessageRouter")
            return
        }

        Log.info("🛑 Handling END_SESSION from \(userId)", category: "MessageRouter")

        // 1. Archive the session — prefer Rust-owned archiving.
        var rustHandled = false
        if CryptoManager.shared.orchestratorCore != nil {
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
            if let actions = try? CryptoManager.shared.handleOrchestratorEvent(event, tag: "end_session_archive") {
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
        onEndSessionReceived?(userId, messageTimestamp)

        Log.info("✅ END_SESSION handled for \(userId)", category: "MessageRouter")
    }
    
    /// Marks outgoing messages that were sent to the server but never delivered as `.queued`,
    /// so they can be re-encrypted and re-sent under the fresh session after END_SESSION.
    /// All `.sent` messages for the contact are considered — the time window is not capped,
    /// because the user may have been offline longer than any fixed window.
    /// Messages that have already been re-queued `maxMessageRetryAttempts` times are permanently
    /// marked as `.failed` to break infinite session-reset amplification cycles.
    private func requeueUndeliveredOutgoing(
        for userId: String,
        in context: NSManagedObjectContext
    ) {
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)
        guard let chat = (try? context.fetch(chatFetch))?.first else { return }

        let msgFetch = Message.fetchRequest()
        msgFetch.predicate = NSPredicate(
            format: "chat == %@ AND isSentByMe == YES AND deliveryStatusRaw == %d",
            chat,
            DeliveryStatus.sent.rawValue
        )
        msgFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        guard let messages = try? context.fetch(msgFetch), !messages.isEmpty else { return }

        let maxRetries = FeatureFlags.maxMessageRetryAttempts
        var requeuedCount = 0
        var droppedCount = 0

        for msg in messages {
            if msg.retryCount < maxRetries {
                msg.deliveryStatus = .queued
                requeuedCount += 1
            } else {
                // Message has survived maxRetries session resets without delivery receipt.
                // Mark permanently failed to break re-queue amplification cycle.
                msg.deliveryStatus = .failed
                droppedCount += 1
                Log.error("⛔ END_SESSION: dropping re-queue for \(msg.id.prefix(8))… after \(msg.retryCount) attempts — marking failed", category: "MessageRouter")
            }
        }
        context.saveAndLog()

        if requeuedCount > 0 {
            Log.info("♻️ END_SESSION: re-queued \(requeuedCount) message(s) for \(userId.prefix(8))… — will resend under new session", category: "MessageRouter")
        }
        if droppedCount > 0 {
            Log.error("⛔ END_SESSION: permanently failed \(droppedCount) message(s) for \(userId.prefix(8))… (exceeded retry limit)", category: "MessageRouter")
        }
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
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0

        message.applyStoredEncryption(plaintext: text, contactId: userId)
        
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
        quotedMessage: Shared_Proto_Messaging_V1_QuotedMessage?,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id ==[c] %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        // Check if message already exists (from background fetch)
        if let existingMessage = try? context.fetch(fetchRequest).first {
            // Update encrypted content if message wasn't previously decrypted
            if !existingMessage.hasDecryptedContent {
                Log.debug("🔄 Updating decrypted content for message \(messageData.id)", category: "MessageRouter")
                existingMessage.applyStoredEncryption(plaintext: decryptedContent, contactId: messageData.from)
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
        message.contentType = .regular
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        message.applyStoredEncryption(plaintext: decryptedContent, contactId: messageData.from)

        // Restore reply-to context so the receiver sees the same reply bubble as the sender.
        // Priority: QuotedMessage from proto plaintext (privacy-safe, no server visibility).
        // Fallback: legacy replyToMessageId from envelope (old clients without proto payload).
        if let qm = quotedMessage, !qm.messageID.isEmpty {
            message.replyToMessageId = qm.messageID.lowercased()
            message.replyToContent = qm.textPreview.isEmpty ? nil : qm.textPreview
        } else if !messageData.replyToMessageId.isEmpty {
            message.replyToMessageId = messageData.replyToMessageId.lowercased()
            let replyFetch = Message.fetchRequest()
            replyFetch.predicate = NSPredicate(format: "id ==[c] %@", messageData.replyToMessageId)
            replyFetch.fetchLimit = 1
            if let replyMsg = (try? context.fetch(replyFetch))?.first {
                let replyText = replyMsg.displayText
                message.replyToContent = replyText.isEmpty ? nil : replyText
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
            guard let decryptResult = try? CryptoManager.shared.decryptMessage(message, contactIdOverride: contactId) else {
                Log.error("❌ SENDER_SYNC: decryption failed for contactId=\(contactId.prefix(20))…", category: "MessageRouter")
                return
            }
            let decrypted = String(data: decryptResult.plaintext, encoding: .utf8) ?? ""
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
        msg.timestamp = Date(timeIntervalSince1970: TimeInterval(original.timestamp))
        msg.isSentByMe = true
        msg.deliveryStatus = .sent
        msg.retryCount = 0
        msg.chat = chat

        msg.applyStoredEncryption(plaintext: decrypted, contactId: partnerUserId)

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
