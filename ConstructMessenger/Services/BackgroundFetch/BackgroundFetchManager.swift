//
//  BackgroundFetchManager.swift
//  Construct Messenger
//
//

import Foundation
#if os(iOS)
import BackgroundTasks
#endif
#if os(iOS)
import UIKit
#endif
import os.log
import CoreData

/// Manages background task scheduling and execution for message fetching
/// Uses BGTaskScheduler for intelligent, energy-efficient background operations
@Observable
class BackgroundFetchManager: NSObject {
    
    // MARK: - Task Identifiers
    
    /// BGAppRefreshTask identifier for periodic message checking (15-30 min intervals)
    static let messageRefreshTaskID = "com.construct.message-refresh"
    
    /// BGProcessingTask identifier for maintenance operations
    static let maintenanceTaskID = "com.construct.maintenance"
    
    // MARK: - Properties
    
    static let shared = BackgroundFetchManager()
    
    /// Energy monitor for battery and network checks
    private let energyMonitor = EnergyMonitor()
    
    // ✅ Using gRPC for fetching messages (WebSocket removed)
    
    /// Indicates if background fetch is enabled by user
    private(set) var isBackgroundFetchEnabled = false
    
    /// Last successful fetch timestamp
    private(set) var lastFetchDate: Date?
    
    /// Last fetch result
    private(set) var lastFetchResult: Result<Int, Error>?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        BackgroundFetchConfig.initializeDefaults()
        
        // Initialize enabled state from config
        isBackgroundFetchEnabled = BackgroundFetchConfig.shouldBeEnabled
        
        // Monitor Low Power Mode changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        
        Log.info("BackgroundFetchManager initialized", category: "BackgroundFetch")
    }
    
    @objc private func lowPowerModeChanged() {
        checkLowPowerMode()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Registration
    
    /// Register background tasks with BGTaskScheduler
    /// Must be called in AppDelegate application(_:didFinishLaunchingWithOptions:)
    /// BEFORE the app finishes launching
    func registerBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.messageRefreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                Log.error("Invalid task type for message refresh", category: "BackgroundFetch")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleMessageRefresh(task: refreshTask)
        }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.maintenanceTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                Log.error("Invalid task type for maintenance", category: "BackgroundFetch")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleMaintenance(task: processingTask)
        }
        Log.info("Background tasks registered successfully")
        #endif
    }
    
    // MARK: - Scheduling
    
    /// Schedule next background fetch task
    func scheduleBackgroundFetch() {
        #if os(iOS)
        guard BackgroundFetchConfig.shouldBeEnabled else {
            Log.info("Background fetch disabled (user setting or Low Power Mode)", category: "BackgroundFetch")
            cancelAllBackgroundTasks()
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.messageRefreshTaskID)
        let interval = BackgroundFetchConfig.interval
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Background fetch scheduled (interval: \(Int(interval / 60)) min)", category: "BackgroundFetch")
        } catch {
            Log.error("Failed to schedule background fetch: \(error)", category: "BackgroundFetch")
        }
        #endif
    }
    
    /// Schedule maintenance task
    func scheduleMaintenanceTask() {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Maintenance task scheduled successfully")
        } catch {
            Log.error("Failed to schedule maintenance task: \(error)")
        }
        #endif
    }
    
    /// Cancel all scheduled background tasks
    func cancelAllBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.messageRefreshTaskID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.maintenanceTaskID)
        #endif
        Log.info("All background tasks cancelled")
    }
    
    // MARK: - Task Handlers
    
    #if os(iOS)
    /// Handle BGAppRefreshTask for message fetching
    private func handleMessageRefresh(task: BGAppRefreshTask) {
        Log.info("Background message refresh started")
        
        // Schedule next refresh immediately
        scheduleBackgroundFetch()
        
        // Set expiration handler (iOS gives 30 seconds)
        task.expirationHandler = {
            Log.error("Background task expired")
            self.cleanupFetch()
            task.setTaskCompleted(success: false)
        }
        
        // Check if we should perform fetch (battery, network, etc.)
        guard energyMonitor.shouldPerformBackgroundFetch() else {
            Log.info("Skipping background fetch due to energy conditions")
            task.setTaskCompleted(success: true)
            return
        }
        
        // Perform the actual fetch with 20-second timeout
        performQuickMessageFetch { result in
            switch result {
            case .success(let messageCount):
                Log.info("Background fetch completed: \(messageCount) new messages")
                self.lastFetchDate = Date()
                self.lastFetchResult = .success(messageCount)
                task.setTaskCompleted(success: true)
                
            case .failure(let error):
                Log.error("Background fetch failed: \(error)")
                self.lastFetchResult = .failure(error)
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    /// Handle BGProcessingTask for maintenance operations
    private func handleMaintenance(task: BGProcessingTask) {
        Log.info("Maintenance task started")
        
        // Set expiration handler
        task.expirationHandler = {
            Log.error("Maintenance task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Perform maintenance operations
        performMaintenance { success in
            Log.info("Maintenance task completed: \(success)")
            task.setTaskCompleted(success: success)
            self.scheduleMaintenanceTask()
        }
    }
    #endif
    
    // MARK: - Fetch Logic
    
    /// Perform quick message fetch with connect-fetch-disconnect pattern
    /// Target execution time: 2-5 seconds
    private func performQuickMessageFetch(completion: @escaping (Result<Int, Error>) -> Void) {
        Log.info("Starting quick message fetch", category: "BackgroundFetch")
        
        // Check authentication
        guard GRPCAuthCache.shared.snapshot.token != nil else {
            Log.error("No session token available", category: "BackgroundFetch")
            completion(.failure(BackgroundFetchError.notAuthenticated))
            return
        }
        
        // Fetch pending messages via gRPC (unary, cursor-paginated)
        Task {
            do {
                var allMessages: [ChatMessage] = []
                var cursor: String? = nil

                repeat {
                    let result = try await MessagingServiceClient.shared.getPendingMessages(
                        sinceCursor: cursor,
                        limit: 50
                    )
                    allMessages.append(contentsOf: result.messages)
                    cursor = result.nextCursor

                    if !result.hasMore { break }
                } while true

                await MainActor.run { [allMessages] in
                    // No sealed pre-resolution here: MessageRouter opens the SealedInner at its
                    // own unseal boundary, which is the single place that knows how to do it.
                    self.processOfflineMessages(allMessages, completion: completion)
                }
            } catch {
                Log.error("Failed to fetch offline messages: \(error.localizedDescription)", category: "BackgroundFetch")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    /// Route the fetched backlog through the SAME pipeline the live stream uses.
    ///
    /// This used to be ~390 lines re-implementing everything `MessageRouter` already does —
    /// control-message filtering, chat lookup, dedup, ACK guards, decrypt, chunk reassembly,
    /// block enforcement, edits, profile shares, persistence, unread + preview. Keeping two
    /// interpretations of an incoming message produced four defects of the same shape, the last
    /// of which (reading `from` without opening the SealedInner) silently killed every push
    /// notification. One path now, so a fix or a new content type lands in both by construction.
    ///
    /// Runs on the MainActor against `viewContext`: the old private-queue context existed only to
    /// keep `NSManagedObjectContextObjectsDidChange` off the main thread, and on the MainActor
    /// that concern is void — FRC/Observable updates fire exactly where they should. The decrypt
    /// already hopped to main anyway, since the Rust core is MainActor-isolated.
    @MainActor
    private func processOfflineMessages(_ messages: [ChatMessage], completion: @escaping (Result<Int, Error>) -> Void) {
        guard !messages.isEmpty else {
            completion(.success(0))
            return
        }
        Log.info("Processing \(messages.count) offline messages", category: "BackgroundFetch")

        guard GRPCAuthCache.shared.snapshot.userId != nil else {
            completion(.failure(BackgroundFetchError.notAuthenticated))
            return
        }

        let context = PersistenceController.shared.container.viewContext
        let countRequest = Message.fetchRequest()
        let before = (try? context.count(for: countRequest)) ?? 0

        // Routed through the shared SessionLifecycleController facade — the app's single
        // MessageRouter instance — so in-flight dedup, the pending-session queue and the
        // SessionCoordinator delegate wiring are the same objects the stream uses. A private
        // router here would race the stream instead of coordinating with it.
        for message in messages {
            SessionLifecycleController.shared.routeIncomingMessage(message, in: context)
        }

        if context.hasChanges {
            context.saveAndLog()
        }

        let after = (try? context.count(for: countRequest)) ?? before
        let saved = max(0, after - before)
        // Notifications are posted by whoever SAVED each message (InAppNotificationService on
        // this path), with IncomingFloodGuard collapsing a large backlog into a single alert —
        // the batch "N messages from M contacts" banner is gone with the duplicate pipeline.
        Log.info("Saved \(saved) new messages to Core Data", category: "BackgroundFetch")
        completion(.success(saved))
    }

    private func cleanupFetch() {
        // WebSocket cleanup is handled by gRPC channel teardown
        // which creates its own temporary connection
        Log.info("Cleaning up fetch resources", category: "BackgroundFetch")
    }
    
    /// Perform maintenance operations (cache cleanup, token minting, etc.)
    private func performMaintenance(completion: @escaping (Bool) -> Void) {
        // Run all maintenance inside one @MainActor Task and call `completion` only after it
        // finishes, so the BGProcessingTask isn't marked complete (and the app suspended) before
        // the async work actually runs.
        Task { @MainActor in
            // Replenish blind tokens during maintenance window (up to 15 per cycle).
            // BlindTokenService enforces 1-hour cooldown to respect server rate limit.
            await BlindTokenService.shared.replenish(count: 15)

            // stealth-sealed-sender-v2 Phase 4: proactively renew the sender certificate
            // ahead of its 24h expiry, now that sealed sending is always on and every
            // message would otherwise pay a cache-miss network fetch on the hot path.
            // getSenderCertificate() is itself a no-op when the cached cert still has
            // more than 5 minutes of validity left. Gated on auth, same as SPK rotation
            // below — no point attempting a network fetch without a valid session.
            if GRPCAuthCache.shared.snapshot.token != nil {
                _ = try? await StealthSenderService.shared.getSenderCertificate()
            }

            // Session health audit: send heartbeats to contacts silent for 12+ hours,
            // then log a health summary for diagnostics. Mirrors the foreground path in
            // applicationWillEnterForeground — keeps sessions alive between launches.
            await SessionActivityTracker.shared.sendStaleSessionHeartbeats()
            SessionActivityTracker.shared.logSessionHealthSummary()

            // Stale-peer reachability Phase 3A: rotate the Signed Pre-Key in the background when it
            // has aged past the rotation threshold, so a long-dormant device keeps a fresh SPK
            // without needing a foreground launch. Otherwise its SPK goes stale and peers'
            // new-session init degrades (at-risk) until the device is woken or next opened.
            // `rotateIfNeeded` is a no-op when the SPK is still fresh and serialises/throttles
            // internally; gated on auth + a ready crypto core so it stays silent when the app was
            // launched into the background without them.
            if GRPCAuthCache.shared.snapshot.token != nil,
               CryptoManager.shared.isCoreReady,
               let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty {
                await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
            }

            completion(true)
        }
    }
    
    // MARK: - User Controls
    
    /// Enable background fetch
    /// Call this when user enables background refresh in settings
    /// Manual pull-to-refresh: fetches pending messages immediately via gRPC.
    func fetchPendingMessages() async {
        await withCheckedContinuation { continuation in
            performQuickMessageFetch { _ in continuation.resume() }
        }
    }

    func enableBackgroundFetch() {
        // Check Low Power Mode
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            Log.info("Cannot enable background fetch: Low Power Mode is enabled", category: "BackgroundFetch")
            BackgroundFetchConfig.isEnabled = false
            isBackgroundFetchEnabled = false
            return
        }
        
        BackgroundFetchConfig.isEnabled = true
        isBackgroundFetchEnabled = true
        scheduleBackgroundFetch()
        Log.info("Background fetch enabled by user", category: "BackgroundFetch")
    }
    
    /// Disable background fetch
    /// Call this when user disables background refresh in settings
    func disableBackgroundFetch() {
        BackgroundFetchConfig.isEnabled = false
        isBackgroundFetchEnabled = false
        cancelAllBackgroundTasks()
        Log.info("Background fetch disabled by user", category: "BackgroundFetch")
    }
    
    /// Update fetch interval
    func updateFetchInterval(_ minutes: Int) {
        BackgroundFetchConfig.intervalMinutes = minutes
        // Reschedule with new interval if enabled
        if isBackgroundFetchEnabled {
            cancelAllBackgroundTasks()
            scheduleBackgroundFetch()
        }
        Log.info("Background fetch interval updated to \(minutes) minutes", category: "BackgroundFetch")
    }
    
    /// Check if Low Power Mode is enabled and disable background fetch if needed
    func checkLowPowerMode() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled && isBackgroundFetchEnabled {
            Log.info("Low Power Mode detected - disabling background fetch", category: "BackgroundFetch")
            disableBackgroundFetch()
        }
    }
    
    /// Get readable status string for UI
    var statusDescription: String {
        if !isBackgroundFetchEnabled {
            return "Disabled"
        }
        
        if let lastFetch = lastFetchDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last check: \(formatter.localizedString(for: lastFetch, relativeTo: Date()))"
        }
        
        return "Enabled, waiting for first check"
    }
    
    // MARK: - Errors
    
    enum BackgroundFetchError: LocalizedError {
        case timeout
        case networkUnavailable
        case lowBattery
        case notAuthenticated
        
        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Background fetch timed out"
            case .networkUnavailable:
                return "Network is not available"
            case .lowBattery:
                return "Battery level too low"
            case .notAuthenticated:
                return "User not authenticated"
            }
        }
    }
}
