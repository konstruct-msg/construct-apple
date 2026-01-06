//
//  BackgroundFetchManager.swift
//  Construct Messenger
//
//  Created by Claude on 03.01.2026.
//

import Foundation
import BackgroundTasks
import Combine
import UIKit
import os.log

/// Manages background task scheduling and execution for message fetching
/// Uses BGTaskScheduler for intelligent, energy-efficient background operations
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

    /// WebSocket manager for fetching messages
    private var webSocketManager: WebSocketManager?

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Indicates if background fetch is enabled by user
    @Published private(set) var isBackgroundFetchEnabled = false

    /// Last successful fetch timestamp
    @Published private(set) var lastFetchDate: Date?

    /// Last fetch result
    @Published private(set) var lastFetchResult: Result<Int, Error>?

    // MARK: - Initialization

    private override init() {
        super.init()
        Log.info("BackgroundFetchManager initialized")
    }

    // MARK: - Registration

    /// Register background tasks with BGTaskScheduler
    /// Must be called in AppDelegate application(_:didFinishLaunchingWithOptions:)
    /// BEFORE the app finishes launching
    func registerBackgroundTasks() {
        // Register BGAppRefreshTask
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.messageRefreshTaskID,
            using: nil
        ) { task in
            self.handleMessageRefresh(task: task as! BGAppRefreshTask)
        }

        // Register BGProcessingTask
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.maintenanceTaskID,
            using: nil
        ) { task in
            self.handleMaintenance(task: task as! BGProcessingTask)
        }

        Log.info("Background tasks registered successfully")
    }

    // MARK: - Scheduling

    /// Schedule next background fetch task
    /// iOS will intelligently decide when to run based on usage patterns
    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: Self.messageRefreshTaskID)

        // Request execution no earlier than 15 minutes from now
        // iOS may schedule it later based on:
        // - Battery level
        // - Network availability
        // - User's usage patterns
        // - Low Power Mode state
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Background fetch scheduled successfully")
        } catch {
            Log.error("Failed to schedule background fetch: \(error)")
        }
    }

    /// Schedule maintenance task
    /// Runs less frequently, only during optimal conditions
    func scheduleMaintenanceTask() {
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceTaskID)

        // Request execution no earlier than 1 hour from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        // Require network and external power for maintenance
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false // Set to true for heavy operations

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Maintenance task scheduled successfully")
        } catch {
            Log.error("Failed to schedule maintenance task: \(error)")
        }
    }

    /// Cancel all scheduled background tasks
    func cancelAllBackgroundTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.messageRefreshTaskID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.maintenanceTaskID)
        Log.info("All background tasks cancelled")
    }

    // MARK: - Task Handlers

    /// Handle BGAppRefreshTask for message fetching
    private func handleMessageRefresh(task: BGAppRefreshTask) {
        Log.info("📬 Background message refresh started")

        // Schedule next refresh immediately
        scheduleBackgroundFetch()

        // Set expiration handler (iOS gives 30 seconds)
        task.expirationHandler = {
            Log.error("⏰ Background task expired")
            self.cleanupFetch()
            task.setTaskCompleted(success: false)
        }

        // Check if we should perform fetch (battery, network, etc.)
        guard energyMonitor.shouldPerformBackgroundFetch() else {
            Log.info("⚠️ Skipping background fetch due to energy conditions")
            task.setTaskCompleted(success: true)
            return
        }

        // Perform the actual fetch with 20-second timeout
        performQuickMessageFetch { result in
            switch result {
            case .success(let messageCount):
                Log.info("✅ Background fetch completed: \(messageCount) new messages")
                self.lastFetchDate = Date()
                self.lastFetchResult = .success(messageCount)
                task.setTaskCompleted(success: true)

            case .failure(let error):
                Log.error("❌ Background fetch failed: \(error)")
                self.lastFetchResult = .failure(error)
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Handle BGProcessingTask for maintenance operations
    private func handleMaintenance(task: BGProcessingTask) {
        Log.info("🔧 Maintenance task started")

        // Set expiration handler
        task.expirationHandler = {
            Log.error("⏰ Maintenance task expired")
            task.setTaskCompleted(success: false)
        }

        // Perform maintenance operations
        performMaintenance { success in
            Log.info("Maintenance task completed: \(success)")
            task.setTaskCompleted(success: success)

            // Schedule next maintenance
            self.scheduleMaintenanceTask()
        }
    }

    // MARK: - Fetch Logic

    /// Perform quick message fetch with connect-fetch-disconnect pattern
    /// Target execution time: 2-5 seconds
    private func performQuickMessageFetch(completion: @escaping (Result<Int, Error>) -> Void) {
        // Create a timeout timer
        var didComplete = false
        let timeoutSeconds: TimeInterval = 20

        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            if !didComplete {
                didComplete = true
                self.cleanupFetch()
                completion(.failure(BackgroundFetchError.timeout))
            }
        }

        // TODO: Implement actual WebSocket connection and message fetching
        // For now, simulate fetch
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if !didComplete {
                didComplete = true

                // Simulate successful fetch with 0 new messages
                // In real implementation:
                // 1. Quick WebSocket connect
                // 2. Send GetOfflineMessages request
                // 3. Receive messages
                // 4. Immediately disconnect
                // 5. Save to Core Data
                // 6. Show local notifications if needed

                completion(.success(0))
            }
        }
    }

    /// Cleanup fetch resources
    private func cleanupFetch() {
        // Disconnect WebSocket if connected
        // Cancel any pending operations
        Log.error("Cleaning up fetch resources")
    }

    /// Perform maintenance operations (cache cleanup, etc.)
    private func performMaintenance(completion: @escaping (Bool) -> Void) {
        // TODO: Implement maintenance operations
        // - Clean old messages from Core Data
        // - Clear image cache
        // - Optimize database

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            completion(true)
        }
    }

    // MARK: - User Controls

    /// Enable background fetch
    /// Call this when user enables background refresh in settings
    func enableBackgroundFetch() {
        isBackgroundFetchEnabled = true
        scheduleBackgroundFetch()
        Log.info("Background fetch enabled by user")
    }

    /// Disable background fetch
    /// Call this when user disables background refresh in settings
    func disableBackgroundFetch() {
        isBackgroundFetchEnabled = false
        cancelAllBackgroundTasks()
        Log.info("Background fetch disabled by user")
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
