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
    /// Grace-period task: fires real disconnect after background grace period.
    /// Cancelled immediately if the user returns to the app before it fires.
    private var backgroundDisconnectTask: Task<Void, Never>?
    /// How long to wait before treating the app as "truly backgrounded" and tearing down
    /// the stream. Brief app-switches (Notification Center, App Switcher, <5 s away) cancel
    /// this task and preserve the live connection — no reconnect penalty.
    /// On macOS, NSApplication.didResignActiveNotification fires on every app-switch (⌘Tab),
    /// so we use a much longer window to avoid constant reconnects while multitasking.
    private static let backgroundGracePeriod: Duration = {
        #if os(macOS)
        return .seconds(300)  // 5 min: resign-active fires on every ⌘Tab, not true backgrounding
        #else
        return .seconds(15)
        #endif
    }()

    // 🔑 OTPK replenishment: check server count once per app session on stream connect
    private var hasPerformedStartupOtpkCheck = false
    // Timestamp of last foreground key-health check to avoid hammering the server.
    private var lastForegroundKeyCheckAt: TimeInterval = 0
    private static let foregroundKeyCheckCooldownSeconds: TimeInterval = 300  // 5 min

    // ✅ Chat ID to open programmatically (e.g., from deep link or Synaps)
    var chatToOpen: String?

    // true when ChatView is on the navigation stack — hides CTTabBar
    var isInChat: Bool = false
    var isInSettings: Bool = false

    // ✅ Selected tab index — used to switch tabs programmatically (e.g., open chat from Synaps)
    var selectedTab: Int = 0

    // ✅ macOS Desktop: show new chat sheet
    var showNewChat: Bool = false

    // ✅ macOS Desktop: focus sidebar search field programmatically
    var sidebarSearchFocused: Bool = false

    // ✅ macOS Desktop: total unread count for Dock badge
    var totalUnreadCount: Int = 0

    // ✅ macOS Desktop: pending drag-dropped image/file → forwarded to active ChatView
    var pendingDroppedImage: PlatformImage? = nil
    var pendingDroppedFileURL: URL? = nil

    // ✅ Message stream (gRPC bidirectional)
    private let streamManager = MessageStreamManager.shared

    // ✅ Session lifecycle coordinator (session init, END_SESSION, healing, KEY_SYNC)
    let sessionCoordinator = SessionCoordinator()

    /// Contacts from whom we've received END_SESSION but for whom no Core Data User record
    /// exists yet (fresh invite, first ever contact). We subscribe to their stream conversation
    /// so the INITIATOR's X3DH message arrives via live stream rather than waiting for
    /// fetchMissedMessages. Entries are cleared once a Chat is created for that userId.
    private var ephemeralSubscriptionUserIds: Set<String> = []
    
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

        // ✅ Ephemeral stream subscription: when END_SESSION arrives from a brand-new contact
        // (no User record yet), subscribe to their conversation stream immediately so the
        // INITIATOR's X3DH message arrives via live stream and not only via fetchMissedMessages.
        sessionCoordinator.onEphemeralSubscriptionNeeded = { [weak self] userId in
            guard let self else { return }
            guard self.ephemeralSubscriptionUserIds.insert(userId).inserted else { return }
            Log.info("📡 Ephemeral stream subscription added for \(userId.prefix(8))… (pending END_SESSION INITIATOR)", category: "ChatsViewModel")
            self.forceReconnectStream()
        }
        
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

                // Register observations on all three tracked properties.
                // capturedState is read here solely to register the @Observable observations —
                // by the time onChange fires the captured values are stale (they reflect the
                // state at registration time, BEFORE the mutation that triggered onChange).
                // We therefore never compare capturedState to lastState; instead we always
                // re-read the current state as `settled` after onChange fires.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = SessionManager.shared.sessionToken
                        _ = self.connectionStatusManager.connectionStatus
                        #if canImport(UIKit)
                        _ = PushNotificationManager.shared.isPushEnabled
                        #endif
                    } onChange: {
                        continuation.resume()
                    }
                }

                // onChange fired — something changed. Yield so any concurrent
                // @Observable mutations (e.g. markStreamConnected()) settle first.
                await Task.yield()
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
                guard settled != lastState else { continue }
                lastState = settled
                Log.debug("📡 Stream state: token=\(settled.hasToken ? "present" : "nil"), status=\(settled.status.displayText), push=\(settled.pushEnabled)", category: "ChatsViewModel")
                self.handlePollingState(settled)
            }
        }
        observationTasks.append(streamTask)
    }
    
    /// Tracks whether the previous polling state had a session token.
    /// Used to detect the transition from unauthenticated → authenticated and
    /// cancel any in-progress backoff so the stream connects immediately.
    private var pollingStateHadToken = false

    private func handlePollingState(_ state: PollingState) {
        if state.hasToken && state.status != ConnectionStatusManager.ConnectionStatus.disconnected {
            if state.pushEnabled {
                Log.info("📱 Push active — stream connected", category: "ChatsViewModel")
            } else {
                Log.info("📡 Connecting message stream", category: "ChatsViewModel")
            }
            // If we just got a token (registration/login just completed), the stream
            // may already be in exponential backoff from pre-auth connection attempts.
            // Use forceReconnect to cancel the backoff and connect immediately instead
            // of waiting for the next retry window (up to 18+ seconds).
            if !pollingStateHadToken {
                pollingStateHadToken = true
                // Skip forceReconnect if a connection attempt is already in progress
                // (e.g. app-active handler fired first). Cancelling and restarting would
                // waste the time already spent on TLS + fetchMissedMessages (~5-10s).
                if streamManager.isActivelyConnecting || streamManager.isConnected {
                    startMessageStream()
                } else {
                    forceReconnectStream()
                }
            } else {
                startMessageStream()
            }
        } else {
            pollingStateHadToken = false
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
        // When the app enters background: start a grace-period timer instead of disconnecting
        // immediately.  If the user returns within 5 s (brief app-switch, notification peek,
        // Control Center) the timer is cancelled and the live stream is preserved — zero
        // reconnect overhead.  If the grace period expires the app is truly in background
        // and we tear down the stream + invalidate the gRPC channel.
        //
        // A UIBackgroundTask is acquired for the grace period so iOS doesn't suspend us
        // before the timer fires (gives the OS the 5 s to keep us running).
        let backgroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appDidEnterBackground) {
                guard let self else { continue }
                Log.debug("📱 App entered background — grace period started (\(Int(Self.backgroundGracePeriod.components.seconds))s)", category: "ChatsViewModel")
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = Task { [weak self] in
                    #if canImport(UIKit)
                    // Acquire a background task so iOS keeps us alive during the grace window.
                    let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "stream-grace") {
                        // Expiry handler: iOS is about to suspend — disconnect immediately.
                        self?.streamManager.pause()
                        GRPCChannelManager.shared.invalidatePersistentClient()
                    }
                    defer {
                        Task { @MainActor in
                            UIApplication.shared.endBackgroundTask(bgTaskId)
                        }
                    }
                    #endif
                    do {
                        try await Task.sleep(for: Self.backgroundGracePeriod)
                    } catch {
                        // Cancelled — user returned before grace period expired.
                        return
                    }
                    guard let self else { return }
                    Log.info("📱 App backgrounded (grace expired) — pausing stream", category: "ChatsViewModel")
                    self.streamManager.pause()
                    // Invalidate the persistent gRPC channel: OS may have closed the TCP socket
                    // during suspension.  The next RPC after foreground creates a fresh channel.
                    GRPCChannelManager.shared.invalidatePersistentClient()
                }
            }
        }
        observationTasks.append(backgroundTask)

        // On foreground: cancel any pending grace-period disconnect first.
        // If the disconnect already fired (app was truly backgrounded), reconnect.
        // If the timer was still pending, the stream is alive — no reconnect needed.
        let activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appDidBecomeActive) {
                guard let self else { continue }
                // Cancel pending disconnect — user returned before grace period expired.
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = nil

                // Verify ICE proxy is still alive — it may have been killed during suspension.
                // Also pre-warms it when DPI was previously detected (network may have changed).
                await IceProxyManager.shared.verifyAliveOrRestart()
                await IceProxyManager.shared.startIfEnabled()

                if self.streamManager.isConnected {
                    // Stream survived the switch — no work needed.
                    Log.info("📱 App became active — stream still alive, skipping reconnect", category: "ChatsViewModel")
                } else if self.streamManager.isActivelyConnecting {
                    // A fresh connection attempt is already in progress (retryCount=0).
                    // This is most likely an ICE failover: the stream timed out in background,
                    // ICE proxy is starting, and the connectLoop will retry via ICE automatically.
                    // Interrupting it now would cancel the ICE startup and restart a direct-path
                    // attempt that DPI will block again.
                    Log.info("📱 App became active — ICE failover in progress, skipping forceReconnect", category: "ChatsViewModel")
                } else {
                    // Stream went down (app was truly backgrounded, or the OS killed the socket).
                    Log.info("📱 App became active — stream is down, reconnecting", category: "ChatsViewModel")
                    self.forceReconnectStream()
                }

                // Check key health on every foreground return (non-blocking, throttled internally).
                await self.checkKeyHealthInBackground()
            }
        }
        observationTasks.append(activeTask)

        // Force reconnect when network interface switches (VPN off → WiFi, WiFi → cellular, etc.).
        // Old TCP connections bound to the previous interface are dead; cancel them and reopen.
        let pathTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .networkPathChanged) {
                guard let self else { continue }
                // If the app is in the background grace period, don't trigger a reconnect now:
                // - iOS fires spurious path-changed notifications when an app is backgrounded.
                // - Reconnecting in background is wasteful — iOS may suspend us before it completes.
                // Instead, just tear down the dead connection and let the foreground handler reconnect.
                if let bgTask = self.backgroundDisconnectTask, !bgTask.isCancelled {
                    Log.info("🌐 Network changed during background grace — deferring reconnect to foreground", category: "ChatsViewModel")
                    bgTask.cancel()
                    self.backgroundDisconnectTask = nil
                    self.streamManager.pause()
                    GRPCChannelManager.shared.invalidatePersistentClient()
                    continue
                }
                Log.info("🌐 Network interface changed — restarting stream and ICE proxy", category: "ChatsViewModel")
                // Restart ICE proxy: its relay connection was bound to the old interface.
                Task { @MainActor in
                    // First verify (and stop) any stale proxy, then start fresh on the new interface.
                    await IceProxyManager.shared.verifyAliveOrRestart()
                    await IceProxyManager.shared.startIfEnabled()
                }
                self.forceReconnectStream()
            }
        }
        observationTasks.append(pathTask)

        // Retry startup RPCs that may have timed out while ICE was on cooldown and direct
        // gRPC was used (DPI blocks new TLS handshakes, so unary RPCs time out even though
        // the existing stream socket keeps heartbeating).
        let iceRecoveryTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .iceRelayRecovered) {
                guard let self else { return }
                Log.info("🧊 ICE recovered — retrying key health check and token registration", category: "ChatsViewModel")
                // Reset the 5-min cooldown so the health check runs immediately.
                self.lastForegroundKeyCheckAt = 0
                await self.checkKeyHealthInBackground()
                // Re-register push tokens in case they failed during the cooldown window.
                await PushNotificationManager.shared.ensureTokenRegistered()
                #if os(iOS)
                await VoIPPushManager.shared.ensureTokenRegistered()
                #endif
            }
        }
        observationTasks.append(iceRecoveryTask)

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
        MessageRouter.shared.onE2EDeliveryReceiptDecrypted = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
        streamManager.connect(contactUserIds: currentConversationIds()) { [weak self] message in
            self?.handleIncomingMessage(message)
        }

        // Parallel run: open engine stream alongside legacy gRPC stream.
        let conversationIds = currentConversationIds()
        if !conversationIds.isEmpty {
            EngineAdapter.shared.dispatch(.openMessageStream(
                conversationIds: conversationIds,
                sinceCursor: nil
            ))
            Log.debug("📡 Engine stream opened for \(conversationIds.count) conversation(s)", category: "ChatsViewModel")
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
                   crypto.oneTimePrekeyCount() == 0 {
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

                // Retry any avatar downloads that failed while offline (e.g. during ICE startup)
                AvatarRetryService.shared.retryPendingAvatarsIfNeeded()
            }
        }

        // Prewarm is intentionally omitted here: forceReconnectStream() always runs before
        // startMessageStream() on first connect and calls prewarmSessions() there. On
        // subsequent reconnects (stream dropped and restarted) sessions already exist, so
        // prewarmSessions() would be a no-op that still triggers a CoreData fetch on every
        // connectionStatus transition (connected → connecting → connected per reconnect cycle).
    }

    /// Cancel any in-progress backoff and reconnect immediately.
    /// Called when app returns to foreground to skip any pending retry delay.
    private func forceReconnectStream() {
        // Don't reconnect when there is no session — this is a no-op at best and
        // creates a flood of UNAUTHENTICATED gRPC channels during first-time registration.
        guard SessionManager.shared.sessionToken != nil else {
            Log.debug("📡 No session — skipping forceReconnect", category: "ChatsViewModel")
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
            MessageRouter.shared.onE2EDeliveryReceiptDecrypted = { [weak self] messageIds in
                self?.handleDeliveryReceipts(messageIds)
            }
            self.streamManager.forceReconnect(contactUserIds: self.currentConversationIds()) { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            self.sessionCoordinator.prewarmSessions(for: self.prewarmEligibleContactIds())

            // Parallel run: re-open engine stream on reconnect.
            let conversationIds = self.currentConversationIds()
            if !conversationIds.isEmpty {
                EngineAdapter.shared.dispatch(.openMessageStream(
                    conversationIds: conversationIds,
                    sinceCursor: nil
                ))
            }
        }
    }

    /// Check OTPK pool and SPK rotation on foreground return.
    /// Throttled to once per 5 minutes to avoid hammering the server on rapid switches.
    private func checkKeyHealthInBackground() async {
        let now = Date().timeIntervalSince1970
        guard now - lastForegroundKeyCheckAt >= Self.foregroundKeyCheckCooldownSeconds else {
            Log.debug("🔑 Key health check skipped — cooldown active", category: "OTPK")
            return
        }
        guard SessionManager.shared.sessionToken != nil else { return }
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        lastForegroundKeyCheckAt = now

        await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
        await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
    }

    private func currentContactIds() -> [String] {
        guard let context = viewContext else { return Array(ephemeralSubscriptionUserIds) }
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id != %@", SessionManager.shared.currentUserId ?? "")
        let users = (try? context.fetch(fetchRequest)) ?? []
        let coreDataIds = Set(users.compactMap { $0.id })
        // Merge ephemeral subscriptions — contacts from whom we received END_SESSION but
        // for whom no User record exists yet. Once their X3DH message arrives and the Chat
        // is created, the User record covers them and the ephemeral entry is cleared.
        return Array(coreDataIds.union(ephemeralSubscriptionUserIds)).sorted()
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
        // Only clear + re-prewarm if there is no active session. If the user already has an
        // active session with this contact (e.g. they scanned a QR code to share a profile
        // for an existing chat), wiping the session would cause an unnecessary END_SESSION
        // storm. Only clear stale/missing sessions so we fetch fresh OTPKs.
        if !CryptoManager.shared.hasSession(for: user.id) {
            CryptoManager.shared.clearArchivedSessions(for: user.id)
            sessionCoordinator.prewarmSessions(for: [user.id])
        }
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

    /// Fully remove a contact (prune synapse): deletes User, Chat+Messages, session.
    func pruneContact(userId: String) {
        chatManagementService.pruneContact(userId: userId)
        forceReconnectStream()
    }

    /// Open the existing chat with a User, or create one if none exists yet.
    func openOrCreateChat(with user: User) {
        // Switch to Chats tab first
        selectedTab = 0
        // If a chat already exists, navigate to it
        if let existingChat = (user.chats as? Set<Chat>)?.first {
            chatToOpen = existingChat.id
            return
        }
        // No chat yet — create one (contact already exists, no need for PublicUserInfo)
        guard let context = viewContext else { return }
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.lastMessageTime = Date()
        do {
            try context.save()
            chatToOpen = chat.id
        } catch {
            Log.error("❌ openOrCreateChat: failed to save: \(error)", category: "ChatsViewModel")
        }
    }

    /// Toggle mute for a chat. Muted chats suppress in-app notification banners.
    func toggleMute(chat: Chat) {
        guard let context = viewContext else { return }
        chat.isMuted.toggle()
        context.saveAndLog()
        Log.info("🔔 Chat \(chat.id) isMuted=\(chat.isMuted)", category: "ChatsViewModel")
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
        // Clear ephemeral subscription once an actual message arrives from this contact —
        // their User record will be created by MessageRouter (findOrCreateChat), so the
        // regular Core Data path takes over for future stream subscriptions.
        let senderId = message.from
        if !senderId.isEmpty, ephemeralSubscriptionUserIds.remove(senderId) != nil {
            Log.info("📡 Ephemeral subscription cleared for \(senderId.prefix(8))… (first message arrived)", category: "ChatsViewModel")
        }
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
                if prev == .failed {
                    // Receipt arrived after false-failure (e.g. END_SESSION re-queue race).
                    // The server had the message all along — correcting status to .delivered.
                    Log.error("📬 Receipt: corrected false-failed message \(messageId) → .delivered", category: "MessageStream")
                } else {
                    Log.info("📬 Receipt: message \(messageId) marked delivered (was \(prev))", category: "MessageStream")
                }
            }
            context.saveAndLog()
        }
    }
}
