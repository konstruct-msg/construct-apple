//
//  TrafficProtectionService.swift
//  Construct Messenger
//
//
//  Swift wrapper around Rust TrafficProtectionManager
//  Implements traffic analysis resistance with energy-efficient dummy messages
//

import Foundation
#if os(iOS)
import UIKit
#endif
import Combine

@MainActor
class TrafficProtectionService: ObservableObject {
    static let shared = TrafficProtectionService()

    // Rust TrafficProtectionManager (UniFFI-generated)
    private var manager: TrafficProtectionManager?

    // Configuration
    #if DEBUG
    // Debug: Allow user to toggle traffic protection
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startScheduler()
            } else {
                stopScheduler()
            }
            saveSettings()
        }
    }
    #else
    // Release: Always enabled for maximum security
    @Published private(set) var isEnabled: Bool = true
    #endif

    // Energy metrics for UI display
    @Published var metrics: EnergyMetrics?

    // Battery monitoring
    private var batteryLevel: Float = TrafficProtectionConfig.defaultBatteryLevel
    private var batteryObserver: NSObjectProtocol?

    // Scheduler for periodic dummy messages
    private var schedulerTimer: Timer?

    private init() {
        #if DEBUG
        // Debug: Load settings from UserDefaults
        loadSettings()
        #else
        // Release: Always enabled, no need to load
        // isEnabled is already set to true
        #endif

        // Create Rust manager with configuration
        let config = createConfig()
        self.manager = TrafficProtectionManager(config: config)

        // Setup battery monitoring
        setupBatteryMonitoring()

        #if DEBUG
        // Debug: Start scheduler if enabled
        if isEnabled {
            startScheduler()
        }
        #else
        // Release: Always start scheduler (always enabled)
        startScheduler()
        #endif
    }

    deinit {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        if let observer = batteryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = false
        #endif
    }

    // MARK: - Configuration

    private func createConfig() -> CoverTrafficConfig {
        return CoverTrafficConfig(
            enabled: isEnabled,
            batteryLevelThreshold: TrafficProtectionConfig.batteryLevelThreshold,
            minIntervalMs: TrafficProtectionConfig.minIntervalMs,
            maxIntervalMs: TrafficProtectionConfig.maxIntervalMs,
            messageSize: TrafficProtectionConfig.messageSize,
            coalesceWithRealMessages: TrafficProtectionConfig.coalesceWithRealMessages,
            coalesceWindowMs: TrafficProtectionConfig.coalesceWindowMs
        )
    }

    // MARK: - Battery Monitoring

    private func setupBatteryMonitoring() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryLevel()
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBatteryLevel()
        }
        #endif
    }

    private func updateBatteryLevel() {
        #if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            self.batteryLevel = level
            manager?.updateBatteryLevel(level: level)
            Log.debug("🔋 Battery updated: \(Int(level * 100))%", category: LogCategory.trafficProtection.name)
        }
        #endif
    }

    // MARK: - Dummy Message Scheduler

    private func startScheduler() {
        guard isEnabled else { return }

        stopScheduler()

        // Check every N seconds (manager will decide if it's time to send)
        schedulerTimer = Timer.scheduledTimer(
            withTimeInterval: TrafficProtectionConfig.schedulerCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkAndSendDummy()
        }

        Log.info("⏰ Traffic protection scheduler started", category: LogCategory.trafficProtection.name)
    }

    private func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        Log.info("⏹️ Traffic protection scheduler stopped", category: LogCategory.trafficProtection.name)
    }

    /// Check if we should send a dummy message and send it if needed
    private func checkAndSendDummy() {
        guard let manager = manager else { return }
        guard isEnabled else { return }

        // Ask Rust manager if we should send (handles timing, battery, coalescing)
        guard manager.shouldSendDummy() else {
            Log.debug("⏭️ Skipping dummy (not ready or battery low)", category: LogCategory.trafficProtection.name)
            return
        }

        // Generate dummy message
        let dummyData = manager.generateDummy()

        // ✅ Cover traffic disabled - TODO: Implement gRPC cover traffic endpoint
        Log.debug("⚠️ Cover traffic disabled, skipping dummy (\(dummyData.count) bytes)", category: LogCategory.trafficProtection.name)
    }

    // MARK: - Real Message Recording

    /// Call this after sending a real message to enable coalescing
    func recordRealMessageSent() {
        manager?.recordRealMessageSent()
    }

    // MARK: - Timing Functions

    /// Get battery-aware send delay for messages
    /// - Parameter isHighPriority: true for user messages, false for background
    /// - Returns: Delay in milliseconds
    func recommendedSendDelay(isHighPriority: Bool) -> UInt64 {
        return recommendedSendDelayMs(isHighPriority: isHighPriority, batteryLevel: batteryLevel)
    }

    /// Apply timing jitter to message sending
    /// - Parameter message: Message to send
    /// - Parameter isHighPriority: Priority of message
    /// - Parameter sendAction: Closure to actually send the message
    func applyTimingJitter(isHighPriority: Bool, sendAction: @escaping @MainActor () -> Void) {
        let delayMs = recommendedSendDelay(isHighPriority: isHighPriority)
        if delayMs > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(delayMs)))
                sendAction()
            }
        } else {
            sendAction()
        }
    }

    // MARK: - Metrics

    func updateMetrics() {
        guard let manager = manager else { return }
        metrics = manager.getMetrics()
    }

    func resetMetrics() {
        manager?.resetMetrics()
        updateMetrics()
    }

    func currentIntervalMs() -> UInt64 {
        return manager?.currentIntervalMs() ?? 0
    }

    func isCurrentlyActive() -> Bool {
        return manager?.isCurrentlyActive() ?? false
    }

    // MARK: - Persistence

    #if DEBUG
    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKey.trafficProtectionEnabled.key)
    }

    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: UserDefaultsKey.trafficProtectionEnabled.key)
    }
    #endif
}
