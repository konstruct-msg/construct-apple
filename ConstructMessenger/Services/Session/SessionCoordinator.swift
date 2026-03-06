//
//  SessionCoordinator.swift
//  Construct Messenger
//
//  Owns the entire session lifecycle for all peers:
//  – Receiving session init (RECEIVER role via X3DH)
//  – Sending END_SESSION (manual reset, logout, heal-exhausted)
//  – Session healing (re-key on messageNumber=0 decrypt failure)
//  – KEY_SYNC handling (re-key sending session on server request)
//  – OTPK replenishment after session init / heal exhaustion
//  – Pending message queue (messages that arrived before a session was ready)
//
//  ChatsViewModel owns stream lifecycle; SessionCoordinator owns session lifecycle.
//

import Foundation
import CoreData

@MainActor
final class SessionCoordinator {

    // MARK: - Owned services

    private let messageRouter = MessageRouter()
    private let publicKeyBundleHandler = PublicKeyBundleHandler()
    private let sessionInitService = SessionInitializationService()
    private let initMessageReassembler = ChunkedMessageReassembler()

    // MARK: - State

    /// Messages that arrived before their sender's session was established.
    /// Keyed by sender userId; ordered by arrival (first element = lowest messageNumber).
    private var pendingFirstMessages: [String: [ChatMessage]] = [:]

    /// Tracks when we last sent END_SESSION to each peer to prevent loop storms.
    private var endSessionSentAt: [String: Date] = [:]
    private let endSessionCooldown: TimeInterval = 30.0

    /// Prevents parallel session-init attempts for the same peer.
    private var usersInitializingSession: Set<String> = []

    // MARK: - Injected references

    private var viewContext: NSManagedObjectContext?
    private weak var streamManager: MessageStreamManager?

    // MARK: - Setup

    func setContext(_ context: NSManagedObjectContext) {
        viewContext = context
        messageRouter.setContext(context)
        publicKeyBundleHandler.setContext(context)
    }

    /// Call once after init to bind MessageRouter callbacks and the stream manager reference.
    func configure(streamManager: MessageStreamManager) {
        self.streamManager = streamManager
        setupMessageRouterCallbacks()
    }

    // MARK: - Public entry points

    /// Route a single incoming message through MessageRouter.
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        messageRouter.routeIncomingMessage(message, in: context, pendingMessages: &pendingFirstMessages)
    }

    /// Called when the stream receives a KEY_SYNC control message.
    func handleKeySyncRequest(for userId: String) {
        guard !usersInitializingSession.contains(userId) else {
            Log.info("⏸️ KEY_SYNC skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        usersInitializingSession.insert(userId)
        Log.info("🔑 SESSION_STATE[key_sync]: re-keying sending session for \(userId.prefix(8))…", category: "SessionInit")
        Task {
            defer { usersInitializingSession.remove(userId) }
            do {
                let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                try sessionInitService.initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
                Log.info("✅ SESSION_STATE[key_sync_success]: session re-keyed for \(userId.prefix(8))…", category: "SessionInit")
            } catch {
                Log.error("❌ SESSION_STATE[key_sync_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
        }
    }

    /// Send END_SESSION to a peer and archive + clear the local session.
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        Log.info("🔄 Sending END_SESSION to \(userId): \(reason)", category: "ChatsViewModel")
        do {
            let response = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: reason)
            Log.info("✅ END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        Log.info("✅ END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
    }

    /// Broadcast END_SESSION to all peers that have an active session (e.g., on logout).
    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("🔄 Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        let sessionUserIds = CryptoManager.shared.getAllSessionUserIds()
        Log.info("📋 Found \(sessionUserIds.count) active sessions", category: "ChatsViewModel")
        var successCount = 0
        var failCount = 0
        for userId in sessionUserIds {
            do {
                try await sendEndSession(to: userId, reason: reason)
                successCount += 1
            } catch {
                Log.error("❌ Failed to send END_SESSION to \(userId): \(error)", category: "ChatsViewModel")
                failCount += 1
            }
        }
        Log.info("✅ END_SESSION broadcast: \(successCount) sent, \(failCount) failed", category: "ChatsViewModel")
    }

    // MARK: - MessageRouter callbacks

    private func setupMessageRouterCallbacks() {
        messageRouter.onReceiptNeeded = { [weak self] messageIds, recipientUserId, status in
            self?.streamManager?.sendReceipt(messageIds, to: recipientUserId, status: status)
        }

        messageRouter.onPublicKeyBundleNeeded = { [weak self] userId, message in
            guard let self else { return }
            Task { @MainActor in
                await self.handlePublicKeyBundleNeeded(userId: userId, message: message)
            }
        }

        messageRouter.onUsernameUpdateNeeded = { [weak self] userId in
            guard let self else { return }
            Task {
                do {
                    let bundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                    await MainActor.run {
                        _ = self.publicKeyBundleHandler.handlePublicKeyBundle(bundle)
                    }
                } catch {
                    Log.error("❌ Failed to fetch public key for username update: \(error.localizedDescription)", category: "ChatsViewModel")
                }
            }
        }

        messageRouter.onEndSessionNeeded = { [weak self] userId in
            guard let self else { return }
            Task {
                let now = Date()
                if let lastSent = self.endSessionSentAt[userId],
                   now.timeIntervalSince(lastSent) < self.endSessionCooldown {
                    Log.info("⏸️ END_SESSION cooldown active for \(userId.prefix(8))..., skipping", category: "ChatsViewModel")
                    return
                }
                self.endSessionSentAt[userId] = now
                Log.info("🔄 Sending END_SESSION to \(userId.prefix(8))... (session out of sync)", category: "ChatsViewModel")
                try? await self.sendEndSession(to: userId, reason: "session_out_of_sync")
            }
        }

        messageRouter.onSessionHealNeeded = { [weak self] userId, failedMessage in
            guard let self else { return }
            Task { @MainActor in
                await self.handleSessionHealNeeded(userId: userId, failedMessage: failedMessage)
            }
        }
    }

    // MARK: - RECEIVER session init

    private func handlePublicKeyBundleNeeded(userId: String, message: ChatMessage) async {
        if usersInitializingSession.contains(userId) {
            Log.info("⏸️ Session init already in progress for \(userId.prefix(8))..., skipping duplicate attempt", category: "SessionInit")
            return
        }
        usersInitializingSession.insert(userId)
        Log.debug("🔒 Locked session init for \(userId.prefix(8))...", category: "SessionInit")

        do {
            let fetchStart = Date()
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
            Log.info("🔐 SESSION_STATE[bundle_fetched]: userId=\(userId.prefix(8))..., duration=\(String(format: "%.2f", Date().timeIntervalSince(fetchStart)))s", category: "SessionInit")

            let success = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: message
            ) { [weak self] chat, msg, decryptedContent in
                self?.saveMessage(for: chat, with: msg, decryptedContent: decryptedContent)
            }

            if success {
                // New session established — reset END_SESSION cooldown so future failures are handled.
                endSessionSentAt.removeValue(forKey: userId)
                // Replenish OTPKs — Bob consumed one OTPK for this X3DH session init.
                Task {
                    let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                    await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                }
                drainPendingQueue(for: userId, skippingFirst: true)
            } else {
                // initReceivingSession failed — prekey exhausted or invalid.
                Log.info("🔄 initReceivingSession failed — clearing queue, sending END_SESSION to \(userId.prefix(8))...", category: "SessionInit")
                // ACK so server cursor advances past the undecryptable message.
                streamManager?.sendReceipt([message.id], to: userId, status: .delivered)
                pendingFirstMessages.removeValue(forKey: userId)
                Task {
                    try? await sendEndSession(to: userId, reason: "session_init_failed")
                    await uploadFreshOtpks(reason: "init_failed")
                }
            }
        } catch {
            Log.error("🔐 SESSION_STATE[bundle_fetch_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
        }

        usersInitializingSession.remove(userId)
        Log.debug("🔓 Unlocked session init for \(userId.prefix(8))...", category: "SessionInit")
    }

    // MARK: - Session healing

    private func handleSessionHealNeeded(userId: String, failedMessage: ChatMessage) async {
        if usersInitializingSession.contains(userId) {
            Log.info("⏸️ Heal skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        usersInitializingSession.insert(userId)
        Log.info("🩹 SESSION_STATE[heal_start]: fetching fresh bundle for \(userId.prefix(8))…", category: "SessionInit")

        defer {
            usersInitializingSession.remove(userId)
            Log.debug("🔓 Heal lock released for \(userId.prefix(8))…", category: "SessionInit")
        }

        guard let context = viewContext else { return }

        let canContinue = SessionHealingService.shared.recordAttempt(
            for: failedMessage.id, in: context
        )

        do {
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)

            let healed = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: failedMessage
            ) { [weak self] chat, msg, decryptedContent in
                self?.saveMessage(for: chat, with: msg, decryptedContent: decryptedContent)
            }

            if healed {
                Log.info("✅ SESSION_STATE[heal_success]: session healed for \(userId.prefix(8))…", category: "SessionInit")
                SessionHealingService.shared.removeRecord(for: failedMessage.id, in: context)
                drainPendingQueue(for: userId, skippingFirst: true)
            } else {
                Log.error("❌ SESSION_STATE[heal_failed]: initReceivingSession still failing for \(userId.prefix(8))…", category: "SessionInit")
                if !canContinue {
                    Log.info("⛔ Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
                    streamManager?.sendReceipt([failedMessage.id], to: userId, status: .delivered)
                    pendingFirstMessages.removeValue(forKey: userId)
                    SessionHealingService.shared.clearQueue(for: userId, in: context)
                    try? await sendEndSession(to: userId, reason: "heal_exhausted")
                    await uploadFreshOtpks(reason: "heal_exhausted")
                }
                // Otherwise leave HealingMessage in CoreData; next reconnect retries.
            }
        } catch {
            Log.error("❌ SESSION_STATE[heal_bundle_error]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            if !canContinue {
                pendingFirstMessages.removeValue(forKey: userId)
                SessionHealingService.shared.clearQueue(for: userId, in: context)
                try? await sendEndSession(to: userId, reason: "heal_bundle_unreachable")
            }
        }
    }

    // MARK: - Helpers

    /// Drain the pending queue for a peer after session init / heal succeeds.
    private func drainPendingQueue(for userId: String, skippingFirst: Bool) {
        let queued = pendingFirstMessages[userId] ?? []
        pendingFirstMessages.removeValue(forKey: userId)
        let toProcess = skippingFirst ? queued.dropFirst() : queued[...]
        guard !toProcess.isEmpty, let context = viewContext else { return }
        Log.info("🔐 Decrypting \(toProcess.count) queued message(s) for \(userId.prefix(8))...", category: "SessionInit")
        for queuedMsg in toProcess {
            messageRouter.routeIncomingMessage(queuedMsg, in: context, pendingMessages: &pendingFirstMessages)
        }
    }

    /// Upload a fresh batch of OTPKs after session-init or heal failure.
    private func uploadFreshOtpks(reason: String) async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        Log.info("🔑 Force-uploading \(OtpkReplenishmentService.replenishBatchSize) fresh OTPKs (\(reason))", category: "OTPK")
        try? await OtpkReplenishmentService.generateAndUpload(
            count: OtpkReplenishmentService.replenishBatchSize,
            deviceId: deviceId,
            replaceExisting: true
        )
    }

    // MARK: - Message persistence (session-init path only)

    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedContent: String) {
        guard let context = viewContext else { return }

        // Unwrap KNST1 chunk envelope to get actual plaintext
        let plaintext: String
        switch initMessageReassembler.process(decryptedText: decryptedContent) {
        case .legacy(let text), .complete(let text):
            plaintext = text
        case .incomplete:
            Log.debug("⏳ Session-init message is a partial chunk — will be reassembled later", category: "SessionCoordinator")
            return
        case .invalid(let reason):
            Log.error("❌ Session-init message envelope invalid: \(reason) — saving raw", category: "SessionCoordinator")
            plaintext = decryptedContent
        }

        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageData.id)

        if let existing = try? context.fetch(fetchRequest).first {
            if existing.decryptedContent == nil {
                existing.decryptedContent = plaintext
                try? context.save()
            }
            return
        }

        let message = Message(context: context)
        message.id = messageData.id
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.encryptedContent = messageData.content
        message.decryptedContent = plaintext
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        chat.lastMessageText = Chat.formatPreviewText(plaintext)
        chat.lastMessageTime = message.timestamp

        try? context.save()
    }
}
