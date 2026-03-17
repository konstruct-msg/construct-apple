//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
class ChatsViewModel {
    private var observationTasks: [Task<Void, Never>] = []
    private var viewContext: NSManagedObjectContext?
    private var didPerformFirstContextSetup = false
    /// Debounce task for forceReconnectStream — prevents channel-creation flood when
    /// multiple observers (networkPathChanged, appDidBecomeActive, etc.) fire at once.
    private var reconnectDebounceTask: Task<Void, Never>?

    // 🔑 OTPK replenishment: check server count once per app session on stream connect
    private var hasPerformedStartupOtpkCheck = false

    // ✅ Chat ID to open programmatically (e.g., from deep link)
    var chatToOpen: String?

    // ✅ Message stream (gRPC bidirectional)
    private let streamManager = MessageStreamManager.shared

    // ✅ Session lifecycle coordinator (session init, END_SESSION, healing, KEY_SYNC)
    let sessionCoordinator = SessionCoordinator()
    
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
        
        // ✅ Configure SessionCoordinator with the shared stream manager
        sessionCoordinator.configure(streamManager: streamManager)
        
        setupSubscribers()
        setupAppLifecycleObservers()
    }

    isolated deinit {
        streamManager.disconnect()
        observationTasks.forEach { $0.cancel() }
    }

    func setContext(_ context: NSManagedObjectContext) {
        if let existing = viewContext, existing === context {
            return
        }
        self.viewContext = context
        sessionCoordinator.setContext(context)
        chatManagementService.setContext(context)
        // Resubscribe with actual contacts now that DB is available.
        // Only force-reconnect if we previously had 0 subscriptions (startup race condition).
        if !didPerformFirstContextSetup && streamManager.subscriptionUserIds.isEmpty {
            didPerformFirstContextSetup = true
            forceReconnectStream()
        }
        // Prune expired ACK and healing records once per app session
        PersistentACKStore.shared.pruneExpired(in: context)
        SessionHealingService.shared.pruneExpired(in: context)
    }

    private func setupSubscribers() {
        // ✅ HYBRID POLLING STRATEGY: Observe auth, connection, and push state via @Observable
        // Uses AsyncStream + withObservationTracking to react to any of the three changing.
        let streamTask = Task { [weak self] in
            var lastState: PollingState? = nil
            while !Task.isCancelled {
                guard let self else { return }

                // Read current state and register for change notification in a single call,
                // eliminating the missed-observation window between two separate tracking blocks.
                var nextState: PollingState!
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        nextState = PollingState(
                            hasToken: SessionManager.shared.sessionToken != nil,
                            status: self.connectionStatusManager.connectionStatus,
                            pushEnabled: {
                                #if canImport(UIKit)
                                PushNotificationManager.shared.isPushEnabled
                                #else
                                false
                                #endif
                            }()
                        )
                    } onChange: {
                        continuation.resume()
                    }
                }

                if nextState != lastState {
                    lastState = nextState
                    // Yield so any pending @Observable property writes (e.g.
                    // markStreamConnected()) settle before we act on the state.
                    await Task.yield()
                    // Re-read after yield in case status changed during yield
                    let settled = PollingState(
                        hasToken: SessionManager.shared.sessionToken != nil,
                        status: self.connectionStatusManager.connectionStatus,
                        pushEnabled: {
                            #if canImport(UIKit)
                            PushNotificationManager.shared.isPushEnabled
                            #else
                            false
                            #endif
                        }()
                    )
                    lastState = settled
                    Log.debug("📡 Stream state: token=\(settled.hasToken ? "present" : "nil"), status=\(settled.status.displayText), push=\(settled.pushEnabled)", category: "ChatsViewModel")
                    self.handlePollingState(settled)
                }
            }
        }
        observationTasks.append(streamTask)
    }
    
    private func handlePollingState(_ state: PollingState) {
        if state.hasToken && state.status != ConnectionStatusManager.ConnectionStatus.disconnected {
            if state.pushEnabled {
                Log.info("📱 Push active — stream connected", category: "ChatsViewModel")
            } else {
                Log.info("📡 Connecting message stream", category: "ChatsViewModel")
            }
            startMessageStream()
        } else {
            if !state.hasToken {
                Log.info("📡 No session — stream stopped", category: "ChatsViewModel")
            } else {
                Log.info("📡 Disconnected (\(state.status.displayText)) — stream stopped", category: "ChatsViewModel")
            }
            stopMessageStream()
        }
    }
    
    // MARK: - App Lifecycle
    
    private func setupAppLifecycleObservers() {
        // Pause stream when app goes to background
        let resignTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appWillResignActive) {
                Log.info("📱 App going to background - pausing messaging", category: "ChatsViewModel")
                self?.streamManager.pause()
            }
        }
        observationTasks.append(resignTask)
        
        // Force reconnect when app becomes active
        let activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appDidBecomeActive) {
                Log.info("📱 App became active — force reconnecting stream", category: "ChatsViewModel")
                self?.forceReconnectStream()
            }
        }
        observationTasks.append(activeTask)

        // Force reconnect when network interface switches (VPN off → WiFi, WiFi → cellular, etc.).
        // Old TCP connections bound to the previous interface are dead; cancel them and reopen.
        let pathTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .networkPathChanged) {
                Log.info("🌐 Network interface changed — restarting stream and ICE proxy", category: "ChatsViewModel")
                // Restart ICE proxy: its relay connection was bound to the old interface.
                Task { @MainActor in
                    await IceProxyManager.shared.startIfEnabled()
                }
                self?.forceReconnectStream()
            }
        }
        observationTasks.append(pathTask)

        // Wake up when silent push arrives (app is in background)
        let silentPushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                #if canImport(UIKit)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = PushNotificationManager.shared.lastSilentPushDate
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if PushNotificationManager.shared.lastSilentPushDate != nil {
                    Log.info("📱 Silent push — reconnecting stream to fetch pending messages", category: "ChatsViewModel")
                    self.forceReconnectStream()
                }
                #else
                try? await Task.sleep(for: .seconds(60))
                #endif
            }
        }
        observationTasks.append(silentPushTask)
    }

    // MARK: - Message Receiving

    func startMessageStream() {
        guard !streamManager.isPaused else {
            Log.debug("📡 Stream paused — skipping startMessageStream", category: "ChatsViewModel")
            return
        }
        streamManager.onDeliveryReceipt = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
        streamManager.onKeySyncReceived = { [weak self] userId in
            self?.sessionCoordinator.handleKeySyncRequest(for: userId)
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

                let crypto = CryptoManager.shared
                // Fallback: core was restored from Keychain but no OTPKs were imported
                // (either first run after migration, or Keychain OTPK data was lost).
                // Replace all server OTPKs with freshly generated ones to guarantee sync.
                if crypto.wasRestoredFromKeychain,
                   let core = crypto.orchestratorCore,
                   core.oneTimePrekeyCount() == 0 {
                    Log.info("🔑 Core restored but no local OTPKs — replacing all server OTPKs (fallback sync)", category: "OTPK")
                    do {
                        try await OtpkReplenishmentService.generateAndUpload(count: 50, deviceId: deviceId, replaceExisting: true)
                    } catch {
                        Log.error("❌ Fallback OTPK replace failed: \(error)", category: "OTPK")
                        await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                    }
                } else {
                    await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                }

                // Check if SPK rotation is due (runs monthly; no-op otherwise)
                await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
            }
        }

        // Pre-warm sessions for contacts where we're the natural INITIATOR (lower UUID)
        // and already have message history. Contacts without history (e.g. just added via QR)
        // are prewarmed in startChat instead, guaranteeing fresh OTPKs after QR scan.
        sessionCoordinator.prewarmSessions(for: prewarmEligibleContactIds())
    }

    /// Cancel any in-progress backoff and reconnect immediately.
    /// Called when app returns to foreground to skip any pending retry delay.
    private func forceReconnectStream() {
        guard SessionManager.shared.sessionToken != nil else {
            Log.info("📱 No session — skipping reconnect", category: "ChatsViewModel")
            return
        }
        // Debounce: if multiple triggers fire within 300 ms (e.g. networkPathChanged +
        // appDidBecomeActive + reachabilityChanged all at once), only the last one runs.
        // This prevents 80+ concurrent connectLoop tasks each creating a gRPC channel.
        reconnectDebounceTask?.cancel()
        reconnectDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.streamManager.onDeliveryReceipt = { [weak self] messageIds in
                self?.handleDeliveryReceipts(messageIds)
            }
            self.streamManager.onKeySyncReceived = { [weak self] userId in
                self?.sessionCoordinator.handleKeySyncRequest(for: userId)
            }
            self.streamManager.forceReconnect(contactUserIds: self.currentConversationIds()) { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            self.sessionCoordinator.prewarmSessions(for: self.prewarmEligibleContactIds())
        }
    }

    private func currentContactIds() -> [String] {
        guard let context = viewContext else { return [] }
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id != %@", SessionManager.shared.currentUserId ?? "")
        let users = (try? context.fetch(fetchRequest)) ?? []
        return users.compactMap { $0.id }
    }

    /// Contact IDs eligible for proactive prewarm on stream connect.
    /// Only includes contacts with an existing message history (Chat.lastMessageTime != nil).
    /// Fresh contacts (added via QR but no messages yet) are excluded — their session is
    /// established via startChat → prewarmSessions after QR scan, not on app launch.
    private func prewarmEligibleContactIds() -> [String] {
        guard let context = viewContext else { return [] }
        let myId = SessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return [] }
        let fetchRequest = Chat.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "lastMessageTime != nil AND otherUser.id != %@", myId)
        let chats = (try? context.fetch(fetchRequest)) ?? []
        return chats.compactMap { $0.otherUser?.id }
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
        // Clear both active and archived sessions so we always prewarm with fresh OTPKs.
        // If the contact was previously in CoreData with a stale prewarm session (e.g. their
        // device was reset), the old session would cause AEAD failure on their side. Archiving
        // and then clearing guarantees the subsequent prewarm fetches their current key bundle.
        CryptoManager.shared.archiveSession(for: user.id, reason: .manualReset)
        CryptoManager.shared.clearArchivedSessions(for: user.id)
        // Prewarm session immediately: if we're the natural INITIATOR (lower UUID),
        // kick off X3DH init now so the first message is instant.
        sessionCoordinator.prewarmSessions(for: [user.id])
        return chat
    }

    // MARK: - END_SESSION Protocol (thin wrappers → SessionCoordinator)

    /// Send END_SESSION to a specific user.
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        try await sessionCoordinator.sendEndSession(to: userId, reason: reason)
    }

    /// Send END_SESSION to all contacts (e.g., on logout).
    func sendEndSessionToAllContacts(reason: String = "logout") async {
        await sessionCoordinator.sendEndSessionToAllContacts(reason: reason)
    }

    // MARK: - Delete Chat

    func deleteChat(chat: Chat) {
        chatManagementService.deleteChat(chat)
    }

    /// Send END_SESSION to peer, then delete the chat locally.
    func deleteChatWithEndSession(chat: Chat) async {
        if let userId = chat.otherUser?.id {
            do {
                try await sessionCoordinator.sendEndSession(to: userId, reason: "chat_deleted")
            } catch {
                Log.error("❌ END_SESSION failed before chat delete (continuing): \(error)", category: "ChatsViewModel")
            }
        }
        chatManagementService.deleteChat(chat)
        // Update stream subscriptions so we stop receiving messages for the deleted chat
        forceReconnectStream()
    }

    // MARK: - Incoming message dispatch

    private func handleIncomingMessage(_ message: ChatMessage) {
        guard let context = viewContext else { return }
        sessionCoordinator.routeIncomingMessage(message, in: context)
    }

    /// Update delivery status to .delivered for messages confirmed by a DeliveryReceipt.
    private func handleDeliveryReceipts(_ messageIds: [String]) {
        guard let context = viewContext else { return }
        context.perform {
            for messageId in messageIds {
                let fetchRequest = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                guard let message = try? context.fetch(fetchRequest).first,
                      message.isSentByMe else { continue }

                // Receipt is authoritative — mark delivered regardless of current state.
                // Strict .sent-only check caused a race: receipt arrived before the gRPC
                // ACK returned, leaving messages permanently stuck at .sent (grey).
                guard message.deliveryStatus != .delivered else { continue }

                let prev = message.deliveryStatus
                message.deliveryStatus = .delivered
                Log.info("📬 Receipt: message \(messageId) marked delivered (was \(prev))", category: "MessageStream")
            }
            context.saveAndLog()
        }
    }
}
