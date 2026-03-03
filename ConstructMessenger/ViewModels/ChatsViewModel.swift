//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine
import CoreData
import UIKit  // ✅ Required for UIApplication notifications

@MainActor
class ChatsViewModel: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var viewContext: NSManagedObjectContext?

    // ✅ Pending messages from users we don't have sessions with yet.
    // Keyed by userId; array is ordered by arrival (first = lowest messageNumber).
    // The first element is used for initReceivingSession; the rest are decrypted afterwards.
    private var pendingFirstMessages: [String: [ChatMessage]] = [:]
    
    // 🚦 Track users currently initializing session (prevents parallel init attempts)
    private var usersInitializingSession: Set<String> = []

    // 🔑 OTPK replenishment: check server count once per app session on stream connect
    private var hasPerformedStartupOtpkCheck = false

    // ✅ Chat ID to open programmatically (e.g., from deep link)
    @Published var chatToOpen: String?

    // ✅ Message stream (gRPC bidirectional)
    private let streamManager = MessageStreamManager()
    
    // ✅ Message router
    private let messageRouter = MessageRouter()
    
    // ✅ Public key bundle handler
    private let publicKeyBundleHandler = PublicKeyBundleHandler()
    private let sessionInitService = SessionInitializationService()

    // Reassembler for KNST1 envelope unwrapping in the session-init message path
    private let initMessageReassembler = ChunkedMessageReassembler()
    
    // ✅ Chat management service
    private let chatManagementService = ChatManagementService()
    
    // ✅ Persistent lastMessageId (survives app restart)
    private var lastMessageId: String? {
        didSet {
            if let id = lastMessageId {
                UserDefaults.standard.set(id, forKey: "construct.lastMessageId")
                Log.debug("💾 Saved lastMessageId: \(id)", category: "ChatsViewModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "construct.lastMessageId")
            }
        }
    }

    // ✅ Connection status
    private let connectionStatusManager = ConnectionStatusManager.shared

    private struct PollingState: Equatable {
        let hasToken: Bool
        let status: ConnectionStatusManager.ConnectionStatus
        let pushEnabled: Bool
    }

    init() {
        // ✅ Restore lastMessageId from persistent storage
        self.lastMessageId = UserDefaults.standard.string(forKey: "construct.lastMessageId")
        if let restored = lastMessageId {
            Log.info("📥 Restored lastMessageId from UserDefaults: \(restored)", category: "ChatsViewModel")
        }
        
        // ✅ Setup MessageRouter callbacks
        setupMessageRouterCallbacks()
        
        setupSubscribers()
        setupAppLifecycleObservers()
    }

    isolated deinit {
        streamManager.disconnect()
    }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
        messageRouter.setContext(context)
        publicKeyBundleHandler.setContext(context)
        chatManagementService.setContext(context)
        // Resubscribe with actual contacts now that DB is available.
        // Only force-reconnect if we previously had 0 subscriptions (startup race condition).
        if streamManager.subscriptionUserIds.isEmpty {
            forceReconnectStream()
        }
        // Prune expired ACK and healing records once per app session
        PersistentACKStore.shared.pruneExpired(in: context)
        SessionHealingService.shared.pruneExpired(in: context)
    }

    private func setupSubscribers() {
        // ✅ HYBRID POLLING STRATEGY: Combine auth, connection, and push notification state
        // Automatically adjust polling behavior based on:
        // 1. Session token is available (user is authenticated)
        // 2. Connection status is .connected (network is available)
        // 3. Push notifications enabled (reduces polling frequency)
        //
        // Polling Strategy:
        // - Push ENABLED: Minimal polling (background only, ~5 min intervals)
        // - Push DISABLED: Full polling (continuous with 30s timeout)
        //
        // TODO: Phase 3 - State Machine Migration
        // This reactive approach works well but consider migrating to explicit
        // State Machine for better control over edge cases like:
        // - Offline mode (queue messages locally)
        // - Reconnection with exponential backoff
        // - Partial connectivity (WiFi without internet)
        // - Token refresh during active polling
        //
        Publishers.CombineLatest3(
            SessionManager.shared.$sessionToken,
            connectionStatusManager.$connectionStatus,
            PushNotificationManager.shared.$isPushEnabled
        )
        .map { token, status, pushEnabled in
            PollingState(hasToken: token != nil, status: status, pushEnabled: pushEnabled)
        }
        .removeDuplicates()
        .sink { [weak self] (state: PollingState) in
            Log.debug("📡 Stream state: token=\(state.hasToken ? "present" : "nil"), status=\(state.status.displayText), push=\(state.pushEnabled)", category: "ChatsViewModel")

            if state.hasToken && state.status != ConnectionStatusManager.ConnectionStatus.disconnected {
                if state.pushEnabled {
                    Log.info("📱 Push active — stream connected", category: "ChatsViewModel")
                } else {
                    Log.info("📡 Connecting message stream", category: "ChatsViewModel")
                }
                self?.startMessageStream()
            } else {
                if !state.hasToken {
                    Log.info("📡 No session — stream stopped", category: "ChatsViewModel")
                } else {
                    Log.info("📡 Disconnected (\(state.status.displayText)) — stream stopped", category: "ChatsViewModel")
                }
                self?.stopMessageStream()
            }
        }
        .store(in: &cancellables)
    }
    
    // MARK: - App Lifecycle
    
    private func setupAppLifecycleObservers() {
        // Pause stream when app goes to background
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Log.info("📱 App going to background - pausing messaging", category: "ChatsViewModel")
                self?.streamManager.pause()
            }
            .store(in: &cancellables)
        
        // Force reconnect when app becomes active — always kick the stream,
        // even if PollingState didn't change (Combine wouldn't fire in that case).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Log.info("📱 App became active — force reconnecting stream", category: "ChatsViewModel")
                self?.forceReconnectStream()
            }
            .store(in: &cancellables)

        // Wake up when silent push arrives (app is in background)
        PushNotificationManager.shared.$lastSilentPushDate
            .compactMap { $0 }
            .sink { [weak self] _ in
                Log.info("📱 Silent push — reconnecting stream to fetch pending messages", category: "ChatsViewModel")
                self?.forceReconnectStream()
            }
            .store(in: &cancellables)
    }

    // MARK: - Message Receiving

    func startMessageStream() {
        streamManager.onDeliveryReceipt = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
        streamManager.onKeySyncReceived = { [weak self] userId in
            self?.handleKeySyncRequest(for: userId)
        }
        streamManager.connect(contactUserIds: currentConversationIds()) { [weak self] message in
            self?.handleIncomingMessage(message)
        }

        // On first stream connect per app session, check if OTPKs need replenishment.
        // Covers the case where OTPKs were consumed while the app was offline.
        if !hasPerformedStartupOtpkCheck {
            hasPerformedStartupOtpkCheck = true
            Task { [weak self] in
                guard self != nil else { return }
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                guard !deviceId.isEmpty else { return }
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
        }
    }

    /// Cancel any in-progress backoff and reconnect immediately.
    /// Called when app returns to foreground to skip any pending retry delay.
    private func forceReconnectStream() {
        guard SessionManager.shared.sessionToken != nil else {
            Log.info("📱 No session — skipping reconnect", category: "ChatsViewModel")
            return
        }
        streamManager.onDeliveryReceipt = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
        streamManager.onKeySyncReceived = { [weak self] userId in
            self?.handleKeySyncRequest(for: userId)
        }
        streamManager.forceReconnect(contactUserIds: currentConversationIds()) { [weak self] message in
            self?.handleIncomingMessage(message)
        }
    }

    private func currentContactIds() -> [String] {
        guard let context = viewContext else { return [] }
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id != %@", SessionManager.shared.currentUserId ?? "")
        let users = (try? context.fetch(fetchRequest)) ?? []
        return users.compactMap { $0.id }
    }

    /// Canonical conversation IDs for all known contacts (used for stream subscription).
    private func currentConversationIds() -> [String] {
        let myId = SessionManager.shared.currentUserId ?? ""
        return currentContactIds().map { ConversationId.direct(myUserId: myId, theirUserId: $0) }
    }

    func stopMessageStream() {
        streamManager.disconnect()
    }

    // MARK: - Start Chat
    func startChat(with user: PublicUserInfo) -> Chat? {
        let chat = chatManagementService.startChat(with: user)
        // New contact added — resubscribe stream so server pushes messages from this contact.
        forceReconnectStream()
        return chat
    }

    // MARK: - END_SESSION Protocol
    
    /// Send END_SESSION to a specific user
    /// This notifies the peer that we're resetting the encrypted session
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        Log.info("🔄 Sending END_SESSION to \(userId): \(reason)", category: "ChatsViewModel")
        
        // 1. Send END_SESSION message via API
        do {
            let response = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: reason)
            Log.info("✅ END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        
        // 2. Archive local session
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        
        // 3. Clear archived sessions (fresh start)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        
        Log.info("✅ END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
    }
    
    /// Send END_SESSION to all contacts (e.g., on logout)
    /// Best-effort delivery - continues even if some fail
    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("🔄 Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        
        // Get all users with active sessions
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
                // Continue anyway - best effort
            }
        }
        
        Log.info("✅ END_SESSION broadcast complete: \(successCount) sent, \(failCount) failed", category: "ChatsViewModel")
    }

    // MARK: - Delete Chat

    func deleteChat(chat: Chat) {
        chatManagementService.deleteChat(chat)
    }

    /// Send END_SESSION to peer, then delete the chat locally.
    func deleteChatWithEndSession(chat: Chat) async {
        if let userId = chat.otherUser?.id {
            do {
                try await sendEndSession(to: userId, reason: "chat_deleted")
            } catch {
                Log.error("❌ END_SESSION failed before chat delete (continuing): \(error)", category: "ChatsViewModel")
            }
        }
        chatManagementService.deleteChat(chat)
    }

    // MARK: - Message Router Setup
    
    private func setupMessageRouterCallbacks() {
        // Send delivery receipts via stream (DELIVERED or FAILED)
        messageRouter.onReceiptNeeded = { [weak self] messageIds, status in
            self?.streamManager.sendReceipt(messageIds, status: status)
        }

        // Callback when public key bundle is needed for incoming message
        messageRouter.onPublicKeyBundleNeeded = { [weak self] userId, message in
            guard let self = self else { return }
            
            // 🚦 Check if already initializing session for this user
            Task { @MainActor in
                if self.usersInitializingSession.contains(userId) {
                    Log.info("⏸️ Session init already in progress for \(userId.prefix(8))..., skipping duplicate attempt", category: "SessionInit")
                    return
                }
                
                // Mark as initializing
                self.usersInitializingSession.insert(userId)
                Log.debug("🔒 Locked session init for \(userId.prefix(8))...", category: "SessionInit")
                
                do {
                    let fetchStartTime = Date()
                    let publicKeyBundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                    let fetchDuration = Date().timeIntervalSince(fetchStartTime)
                    Log.info("🔐 SESSION_STATE[bundle_fetched]: userId=\(userId.prefix(8))..., duration=\(String(format: "%.2f", fetchDuration))s", category: "SessionInit")
                    
                    let success = self.publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                        publicKeyBundle,
                        message: message
                    ) { chat, message, decryptedContent in
                        // Save the decrypted message
                        self.saveMessage(for: chat, with: message, decryptedContent: decryptedContent)
                    }
                    
                    if success {
                        // Replenish OTPKs if server count drops below low-water mark.
                        // Bob consumes one OTPK per incoming session-init, so we top up asynchronously.
                        Task {
                            let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                            await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                        }

                        // Decrypt any messages that queued up while we were initialising the session.
                        let queued = self.pendingFirstMessages[userId] ?? []
                        self.pendingFirstMessages.removeValue(forKey: userId)

                        // Skip the first message (already handled by handlePublicKeyBundleForIncomingMessage).
                        let remaining = queued.dropFirst()
                        if !remaining.isEmpty {
                            Log.info("🔐 Decrypting \(remaining.count) queued message(s) for \(userId.prefix(8))...", category: "SessionInit")
                            guard let context = self.viewContext else { return }
                            for queuedMsg in remaining {
                                self.messageRouter.routeIncomingMessage(queuedMsg, in: context, pendingMessages: &self.pendingFirstMessages)
                            }
                        }
                    } else {
                        // initReceivingSession failed — the sender's prekey for this session is
                        // exhausted and cannot be reused. Clear the pending queue and ask the
                        // sender to start a fresh X3DH session with new prekeys.
                        Log.info("🔄 initReceivingSession failed — clearing queue, sending END_SESSION to \(userId.prefix(8))...", category: "SessionInit")
                        self.pendingFirstMessages.removeValue(forKey: userId)
                        Task {
                            try? await self.sendEndSession(to: userId, reason: "session_init_failed")
                        }
                    }
                    
                    // ✅ Always unlock after completion (success or failure)
                    self.usersInitializingSession.remove(userId)
                    Log.debug("🔓 Unlocked session init for \(userId.prefix(8))...", category: "SessionInit")
                    
                } catch {
                    Log.error("🔐 SESSION_STATE[bundle_fetch_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
                    Log.error("❌ Failed to fetch public key after retries: \(error.localizedDescription)", category: "ChatsViewModel")
                    
                    // ✅ Unlock even on error
                    self.usersInitializingSession.remove(userId)
                    Log.debug("🔓 Unlocked session init for \(userId.prefix(8))... (after error)", category: "SessionInit")
                }
            }
        }
        
        // Callback when username update is needed
        messageRouter.onUsernameUpdateNeeded = { [weak self] userId in
            guard let self = self else { return }
            Task {
                do {
                    let publicKeyBundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                    await MainActor.run {
                        _ = self.publicKeyBundleHandler.handlePublicKeyBundle(publicKeyBundle)
                    }
                } catch {
                    Log.error("❌ Failed to fetch public key for username update: \(error.localizedDescription)", category: "ChatsViewModel")
                }
            }
        }

        // Callback when receiver has no session but messageNumber > 0 — sender must restart
        messageRouter.onEndSessionNeeded = { [weak self] userId in
            guard let self = self else { return }
            Task {
                Log.info("🔄 Sending END_SESSION to \(userId.prefix(8))... (session out of sync)", category: "ChatsViewModel")
                try? await self.sendEndSession(to: userId, reason: "session_out_of_sync")
            }
        }

        // Callback when existing session failed to decrypt a messageNumber=0 message (remote re-keyed).
        // We attempt to heal by fetching a fresh bundle and re-running initReceivingSession,
        // WITHOUT sending END_SESSION to the remote peer.
        messageRouter.onSessionHealNeeded = { [weak self] userId, failedMessage in
            guard let self = self else { return }

            Task { @MainActor in
                // Reuse the same gate as normal session init to prevent concurrent heal+init
                if self.usersInitializingSession.contains(userId) {
                    Log.info("⏸️ Heal skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
                    return
                }
                self.usersInitializingSession.insert(userId)
                Log.info("🩹 SESSION_STATE[heal_start]: fetching fresh bundle for \(userId.prefix(8))…", category: "SessionInit")

                defer {
                    self.usersInitializingSession.remove(userId)
                    Log.debug("🔓 Heal lock released for \(userId.prefix(8))…", category: "SessionInit")
                }

                guard let context = self.viewContext else { return }

                // Track attempt count
                let canContinue = SessionHealingService.shared.recordAttempt(
                    for: failedMessage.id, in: context
                )

                do {
                    let bundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)

                    let healed = self.publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                        bundle,
                        message: failedMessage
                    ) { chat, msg, decryptedContent in
                        self.saveMessage(for: chat, with: msg, decryptedContent: decryptedContent)
                    }

                    if healed {
                        Log.info("✅ SESSION_STATE[heal_success]: session healed for \(userId.prefix(8))…", category: "SessionInit")
                        SessionHealingService.shared.removeRecord(for: failedMessage.id, in: context)

                        // Drain any remaining queued messages now that the session is live
                        let queued = self.pendingFirstMessages[userId] ?? []
                        self.pendingFirstMessages.removeValue(forKey: userId)
                        for queuedMsg in queued.dropFirst() {
                            self.messageRouter.routeIncomingMessage(
                                queuedMsg, in: context, pendingMessages: &self.pendingFirstMessages
                            )
                        }
                    } else {
                        Log.error("❌ SESSION_STATE[heal_failed]: initReceivingSession still failing for \(userId.prefix(8))…", category: "SessionInit")

                        if !canContinue {
                            // Exhausted all heal attempts — escalate to END_SESSION
                            Log.info("⛔ Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
                            self.pendingFirstMessages.removeValue(forKey: userId)
                            SessionHealingService.shared.clearQueue(for: userId, in: context)
                            try? await self.sendEndSession(to: userId, reason: "heal_exhausted")
                        }
                        // Otherwise leave the HealingMessage in CoreData; next reconnect retries
                    }
                } catch {
                    Log.error("❌ SESSION_STATE[heal_bundle_error]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    if !canContinue {
                        self.pendingFirstMessages.removeValue(forKey: userId)
                        SessionHealingService.shared.clearQueue(for: userId, in: context)
                        try? await self.sendEndSession(to: userId, reason: "heal_bundle_unreachable")
                    }
                }
            }
        }
    }
    
    // MARK: - Handle END_SESSION
    
    /// Handle incoming END_SESSION control message
    
    private func handleIncomingMessage(_ message: ChatMessage) {
        guard let context = viewContext else { return }
        
        // Delegate to MessageRouter
        messageRouter.routeIncomingMessage(message, in: context, pendingMessages: &pendingFirstMessages)
    }

    /// Update delivery status to .delivered for messages confirmed by a DeliveryReceipt from the stream.
    private func handleDeliveryReceipts(_ messageIds: [String]) {
        guard let context = viewContext else { return }
        context.perform {
            for messageId in messageIds {
                let fetchRequest = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                guard let message = try? context.fetch(fetchRequest).first,
                      message.isSentByMe,
                      message.deliveryStatus == .sent else { continue }
                message.deliveryStatus = .delivered
                Log.info("📬 Receipt: message \(messageId) marked delivered", category: "MessageStream")
            }
            try? context.save()
        }
    }
    
    /// Handle KEY_SYNC from server: proactively re-init our SENDING session for the peer.
    /// Next message we send will carry a fresh X3DH header (messageNumber=0).
    private func handleKeySyncRequest(for userId: String) {
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
    
    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedContent: String) {
        guard let context = viewContext else { return }

        // Unwrap KNST1 chunk envelope to get the actual plaintext
        let plaintext: String
        switch initMessageReassembler.process(decryptedText: decryptedContent) {
        case .legacy(let text), .complete(let text):
            plaintext = text
        case .incomplete:
            Log.debug("⏳ Session-init message is a partial chunk — will be reassembled later", category: "ChatsViewModel")
            return
        case .invalid(let reason):
            Log.error("❌ Session-init message envelope invalid: \(reason) — saving raw", category: "ChatsViewModel")
            plaintext = decryptedContent
        }
        
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id == %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        // Check if message already exists
        if let existingMessage = try? context.fetch(fetchRequest).first {
            if existingMessage.decryptedContent == nil {
                existingMessage.decryptedContent = plaintext
                try? context.save()
            }
            return
        }
        
        // Create new message
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

        // Update chat preview with correct plaintext
        chat.lastMessageText = Chat.formatPreviewText(plaintext)
        chat.lastMessageTime = message.timestamp
        
        try? context.save()
    }
    
    // MARK: - Message Persistence
    
}
