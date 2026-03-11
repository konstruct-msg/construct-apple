//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
import UIKit  // ✅ Required for UIApplication notifications

@Observable
@MainActor
class ChatsViewModel {
    private var observationTasks: [Task<Void, Never>] = []
    private var viewContext: NSManagedObjectContext?

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
        self.viewContext = context
        sessionCoordinator.setContext(context)
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
                            pushEnabled: PushNotificationManager.shared.isPushEnabled
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
                        pushEnabled: PushNotificationManager.shared.isPushEnabled
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

        // Wake up when silent push arrives (app is in background)
        let silentPushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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
                   let core = crypto.core,
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
            self?.sessionCoordinator.handleKeySyncRequest(for: userId)
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
            try? context.save()
        }
    }
}
