//
//  StreamLifecycleCoordinator.swift
//  Construct Messenger
//
//  Owns the stream connection lifecycle that previously lived in ChatsViewModel:
//  app lifecycle observers (background/foreground/network/ICE/silent-push), the
//  connection-status polling loop, start/stop/forceReconnect, OTPK startup check,
//  ephemeral subscriptions, incoming message dispatch, and delivery receipt marking.
//
//  ChatsViewModel keeps UI state and thin operation wrappers; this class keeps
//  everything that is about *when* and *how* the stream runs.
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class StreamLifecycleCoordinator {
    private static weak var activeCoordinator: StreamLifecycleCoordinator?

    // MARK: - Dependencies

    private let streamManager: MessageStreamManager
    private let sessionCoordinator: SessionCoordinator
    private var viewContext: NSManagedObjectContext?

    // MARK: - Task management

    private var observationTasks: [Task<Void, Never>] = []
    private var reconnectDebounceTask: Task<Void, Never>?
    private var backgroundDisconnectTask: Task<Void, Never>?
    private var foregroundSettleTask: Task<Void, Never>?
    private var isStarted = false

    /// Coalescing window for `appDidBecomeActive`. CallKit UI, Control Center and system alerts
    /// emit bursts of active/inactive transitions (observed 3 in one second during an incoming
    /// call); without this, each one re-ran VEIL startup + reconnect, thrashing the proxy.
    private static let foregroundSettleDelay: Duration = .milliseconds(400)

    private static let backgroundGracePeriod: Duration = {
        #if os(macOS)
        return .seconds(300)
        #else
        return .seconds(15)
        #endif
    }()

    // MARK: - Key health state

    private var hasPerformedStartupOtpkCheck = false
    private var lastForegroundKeyCheckAt: TimeInterval = 0
    private static let foregroundKeyCheckCooldownSeconds: TimeInterval = 300

    // MARK: - Polling state

    private var pollingStateHadToken = false
    private var lastPolledStatus: ConnectionStatusManager.ConnectionStatus = .unknown
    private let connectionStatusManager = ConnectionStatusManager.shared

    private struct PollingState: Equatable {
        let hasToken: Bool
        let status: ConnectionStatusManager.ConnectionStatus
        let pushEnabled: Bool
    }

    // MARK: - Ephemeral subscriptions

    private var ephemeralSubscriptionUserIds: Set<String> = []

    /// Add a one-off stream subscription for a contact who has no User record yet.
    /// Returns true if the userId was newly inserted (caller can use this to avoid
    /// duplicate log lines if needed). Triggers a forceReconnect when inserted.
    @discardableResult
    func addEphemeralSubscription(for userId: String) -> Bool {
        guard ephemeralSubscriptionUserIds.insert(userId).inserted else { return false }
        Log.info("Ephemeral stream subscription added for \(userId.prefix(8))… (pending END_SESSION INITIATOR)", category: "StreamLifecycle")
        forceReconnect()
        return true
    }

    // MARK: - Init

    init(streamManager: MessageStreamManager, sessionCoordinator: SessionCoordinator) {
        self.streamManager = streamManager
        self.sessionCoordinator = sessionCoordinator
    }

    // MARK: - Lifecycle

    func setContext(_ context: NSManagedObjectContext) {
        viewContext = context
    }

    func start() {
        if let active = Self.activeCoordinator, active !== self {
            Log.info("StreamLifecycle start superseding previous coordinator instance", category: "StreamLifecycle")
            active.stop()
        }
        guard !isStarted else {
            Log.debug("StreamLifecycle start ignored — already started", category: "StreamLifecycle")
            return
        }
        Self.activeCoordinator = self
        isStarted = true
        setupSubscribers()
        setupAppLifecycleObservers()
    }

    func stop() {
        isStarted = false
        reconnectDebounceTask?.cancel()
        reconnectDebounceTask = nil
        foregroundSettleTask?.cancel()
        foregroundSettleTask = nil
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        streamManager.disconnect()
        if Self.activeCoordinator === self {
            Self.activeCoordinator = nil
        }
    }

    // MARK: - Stream control

    func startMessageStream(reason: String = "?") {
        guard !streamManager.isPaused else {
            Log.debug("Stream paused — skipping startMessageStream", category: "StreamLifecycle")
            return
        }
        let ids = currentConversationIds()
        guard !ids.isEmpty || streamManager.subscriptionUserIds.isEmpty else {
            Log.debug("startMessageStream — skipping empty ids (would clear \(streamManager.subscriptionUserIds.count) active subscriptions)", category: "StreamLifecycle")
            return
        }
        wireStreamCallbacks()
        streamManager.connect(contactUserIds: ids, trigger: "startMessageStream(\(reason))") { [weak self] message in
            self?.handleIncomingMessage(message)
        }
        #if !os(macOS)
        if !hasPerformedStartupOtpkCheck {
            hasPerformedStartupOtpkCheck = true
            Task { [weak self] in
                guard self != nil else { return }
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                guard !deviceId.isEmpty else { return }
                let crypto = CryptoManager.shared
                if crypto.wasRestoredFromKeychain, crypto.oneTimePrekeyCount() == 0 {
                    Log.info("Core restored but no local OTPKs — replacing all server OTPKs (fallback sync)", category: "OTPK")
                    do {
                        try await OtpkReplenishmentService.generateAndUpload(count: 50, deviceId: deviceId, replaceExisting: true)
                    } catch {
                        Log.error("Fallback OTPK replace failed: \(error)", category: "OTPK")
                        await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                    }
                } else {
                    await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                }
                await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
                AvatarRetryService.shared.retryPendingAvatarsIfNeeded()
            }
        }
        #endif
    }

    func stopMessageStream() {
        streamManager.disconnect()
    }

    func forceReconnect() {
        guard AuthSessionManager.shared.sessionToken != nil else {
            Log.debug("No session — skipping forceReconnect", category: "StreamLifecycle")
            return
        }
        reconnectDebounceTask?.cancel()
        reconnectDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.wireStreamCallbacks()
            self.streamManager.forceReconnect(contactUserIds: self.currentConversationIds()) { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            self.sessionCoordinator.prewarmSessions(for: self.prewarmEligibleContactIds())
        }
    }

    /// Runs the foreground-settle work once per burst of `appDidBecomeActive` events.
    /// Each event reschedules the task; only the final one (after `foregroundSettleDelay` of
    /// quiet) performs VEIL startup + a conditional reconnect + key health.
    private func scheduleForegroundSettle() {
        foregroundSettleTask?.cancel()
        foregroundSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.foregroundSettleDelay)
            guard !Task.isCancelled, let self else { return }
            await VeilProxyManager.shared.verifyAliveOrRestart()
            await VeilProxyManager.shared.startIfEnabled()
            if self.streamManager.isConnected {
                Log.info("App became active — stream still alive, skipping reconnect", category: "StreamLifecycle")
            } else if self.streamManager.isActivelyConnecting {
                Log.info("App became active — stream is connecting, skipping forceReconnect", category: "StreamLifecycle")
            } else {
                Log.info("App became active — stream is down, reconnecting", category: "StreamLifecycle")
                self.forceReconnect()
            }
            await self.checkKeyHealthInBackground()
        }
    }

    // MARK: - Connection status polling

    private func setupSubscribers() {
        let streamTask = Task { [weak self] in
            var lastState: PollingState? = nil
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AuthSessionManager.shared.sessionToken
                        _ = self.connectionStatusManager.connectionStatus
                        #if canImport(UIKit)
                        _ = PushNotificationManager.shared.isPushEnabled
                        #endif
                    } onChange: {
                        continuation.resume()
                    }
                }
                await Task.yield()
                let settled = PollingState(
                    hasToken: AuthSessionManager.shared.sessionToken != nil,
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
                Log.debug("Stream state: token=\(settled.hasToken ? "present" : "nil"), status=\(settled.status.text()), push=\(settled.pushEnabled)", category: "StreamLifecycle")
                self.handlePollingState(settled)
            }
        }
        observationTasks.append(streamTask)
    }

    private func handlePollingState(_ state: PollingState) {
        let didJustConnect = lastPolledStatus != .connected && state.status == .connected
        lastPolledStatus = state.status

        #if !os(macOS)
        if didJustConnect && PreKeyRotationService.shared.hasPendingRetry {
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                guard !deviceId.isEmpty else { return }
                Log.info("Stream reconnected — retrying pending SPK rotation", category: "SPKRotation")
                await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
            }
        }
        #endif

        if state.hasToken && state.status != ConnectionStatusManager.ConnectionStatus.disconnected {
            if state.pushEnabled {
                Log.info("Push active — stream connected", category: "StreamLifecycle")
            } else {
                Log.info("Connecting message stream", category: "StreamLifecycle")
            }
            if !pollingStateHadToken {
                pollingStateHadToken = true
                if streamManager.isActivelyConnecting || streamManager.isConnected {
                    startMessageStream(reason: "pollingFirstToken")
                } else {
                    forceReconnect()
                }
            } else {
                startMessageStream(reason: "pollingStatusChange(\(state.status.text()))")
            }
        } else {
            pollingStateHadToken = false
            if !state.hasToken {
                Log.info("No session — stream stopped", category: "StreamLifecycle")
            } else {
                Log.info("Disconnected (\(state.status.text())) — stream stopped", category: "StreamLifecycle")
            }
            stopMessageStream()
        }
    }

    // MARK: - App lifecycle

    private func setupAppLifecycleObservers() {
        #if canImport(UIKit)
        let backgroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appDidEnterBackground) {
                guard let self else { continue }
                Log.debug("App entered background — grace period started (\(Int(Self.backgroundGracePeriod.components.seconds))s)", category: "StreamLifecycle")
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = Task { [weak self] in
                    let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "stream-grace") {
                        self?.streamManager.pause()
                        GRPCChannelManager.shared.invalidatePersistentClient()
                    }
                    defer {
                        Task { @MainActor in
                            UIApplication.shared.endBackgroundTask(bgTaskId)
                        }
                    }
                    do {
                        try await Task.sleep(for: Self.backgroundGracePeriod)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    Log.info("App backgrounded (grace expired) — pausing stream", category: "StreamLifecycle")
                    self.streamManager.pause()
                    GRPCChannelManager.shared.invalidatePersistentClient()
                }
            }
        }
        observationTasks.append(backgroundTask)
        #endif

        let activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appDidBecomeActive) {
                guard let self else { continue }
                // Cancel the pending background pause immediately — we're back, don't tear down.
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = nil
                // Debounce the heavy foreground work (VEIL startup + reconnect + key health) so a
                // burst of active/inactive flaps (CallKit, Control Center, alerts) runs it once.
                self.scheduleForegroundSettle()
            }
        }
        observationTasks.append(activeTask)

        let pathTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .networkPathChanged) {
                guard let self else { continue }
                if let bgTask = self.backgroundDisconnectTask, !bgTask.isCancelled {
                    Log.info("Network changed during background grace — deferring reconnect to foreground", category: "StreamLifecycle")
                    bgTask.cancel()
                    self.backgroundDisconnectTask = nil
                    self.streamManager.pause()
                    GRPCChannelManager.shared.invalidatePersistentClient()
                    continue
                }
                Log.info("Network interface changed — restarting stream and ICE proxy", category: "StreamLifecycle")
                Task { @MainActor in
                    await VeilProxyManager.shared.verifyAliveOrRestart()
                    await VeilProxyManager.shared.startIfEnabled()
                }
                self.forceReconnect()
            }
        }
        observationTasks.append(pathTask)

        let veilRecoveryTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .veilRelayRecovered) {
                guard let self else { return }
                Log.info("VEIL recovered — retrying key health check and token registration", category: "StreamLifecycle")
                self.lastForegroundKeyCheckAt = 0
                await self.checkKeyHealthInBackground()
                await PushNotificationManager.shared.ensureTokenRegistered()
                #if os(iOS)
                await VoIPPushManager.shared.ensureTokenRegistered()
                #endif
            }
        }
        observationTasks.append(veilRecoveryTask)

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
                    // A silent push that lands while the app is foreground with a LIVE stream is
                    // redundant — the stream already delivered the message. Reconnecting here was
                    // the residual churn driver (one full reconnect per incoming message; device
                    // logs showed "Silent push — reconnecting stream" → forceReconnect on every
                    // push). This mirrors the same guard on the BackgroundFetchManager path in
                    // AppDelegate. When the stream is DOWN (or app backgrounded) we still
                    // reconnect to fetch pending messages — that is the legitimate wake-up case.
                    if UIApplication.shared.applicationState == .active, self.streamManager.isConnected {
                        Log.info("Silent push — foreground stream live, skipping reconnect", category: "StreamLifecycle")
                    } else {
                        Log.info("Silent push — reconnecting stream to fetch pending messages", category: "StreamLifecycle")
                        self.forceReconnect()
                    }
                }
                #else
                try? await Task.sleep(for: .seconds(60))
                #endif
            }
        }
        observationTasks.append(silentPushTask)
    }

    // MARK: - Incoming message + delivery receipts

    private func handleIncomingMessage(_ message: ChatMessage) {
        let context: NSManagedObjectContext
        if let viewContext {
            context = viewContext
        } else {
            Log.error("Incoming message \(message.id.prefix(8))… arrived before StreamLifecycle context was set — using shared context", category: "StreamLifecycle")
            let fallback = PersistenceController.shared.container.viewContext
            setContext(fallback)
            context = fallback
        }

        Log.debug("Dispatching incoming message \(message.id.prefix(8))… from=\(message.from.prefix(8))…", category: "StreamLifecycle")
        let senderId = message.from
        if !senderId.isEmpty, ephemeralSubscriptionUserIds.remove(senderId) != nil {
            Log.info("Ephemeral subscription cleared for \(senderId.prefix(8))… (first message arrived)", category: "StreamLifecycle")
        }
        sessionCoordinator.routeIncomingMessage(message, in: context)
    }

    private func handleDeliveryReceipts(_ messageIds: [String]) {
        guard let context = viewContext else { return }
        context.perform {
            for messageId in messageIds {
                let fetchRequest = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                guard let message = try? context.fetch(fetchRequest).first,
                      message.isSentByMe else { continue }
                guard message.deliveryStatus != .delivered else { continue }
                let prev = message.deliveryStatus
                message.deliveryStatus = .delivered
                if prev == .failed {
                    Log.error("Receipt: corrected false-failed message \(messageId) → .delivered", category: "MessageStream")
                } else {
                    Log.info("Receipt: message \(messageId) marked delivered (was \(prev))", category: "MessageStream")
                }
            }
            context.saveAndLog()
        }
    }

    // MARK: - Key health

    private func checkKeyHealthInBackground() async {
        #if !os(macOS)
        let now = Date().timeIntervalSince1970
        guard now - lastForegroundKeyCheckAt >= Self.foregroundKeyCheckCooldownSeconds else {
            Log.debug("Key health check skipped — cooldown active", category: "OTPK")
            return
        }
        guard AuthSessionManager.shared.sessionToken != nil else { return }
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        lastForegroundKeyCheckAt = now
        await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
        await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
        #endif
    }

    // MARK: - Contact helpers

    private func currentContactIds() -> [String] {
        guard let context = viewContext else { return Array(ephemeralSubscriptionUserIds) }
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id != %@", AuthSessionManager.shared.currentUserId ?? "")
        let users = (try? context.fetch(fetchRequest)) ?? []
        let coreDataIds = Set(users.compactMap { $0.id })
        return Array(coreDataIds.union(ephemeralSubscriptionUserIds)).sorted()
    }

    private func prewarmEligibleContactIds() -> [String] {
        guard let context = viewContext else { return [] }
        let myId = AuthSessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return [] }
        let fetchRequest = Chat.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "lastMessageTime != nil AND otherUser.id != %@", myId)
        let chats = (try? context.fetch(fetchRequest)) ?? []
        return chats.compactMap { $0.otherUser?.id }
    }

    private func currentConversationIds() -> [String] {
        let myId = AuthSessionManager.shared.currentUserId ?? ""
        return currentContactIds().map { ConversationId.direct(myUserId: myId, theirUserId: $0) }
    }

    // MARK: - Callback wiring

    private func wireStreamCallbacks() {
        streamManager.onDeliveryReceipt = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
        streamManager.onKeySyncReceived = { [weak self] userId in
            self?.sessionCoordinator.handleKeySyncRequest(for: userId)
        }
        sessionCoordinator.onE2EDeliveryReceiptDecrypted = { [weak self] messageIds in
            self?.handleDeliveryReceipts(messageIds)
        }
    }
}
