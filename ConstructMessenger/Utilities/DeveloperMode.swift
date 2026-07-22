//
//  DeveloperMode.swift
//  ConstructMessenger
//
//  Hidden developer mode for internal debugging
//  Activation: Tap app version 10 times in Settings
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@Observable
class DeveloperMode {
    static let shared = DeveloperMode()
    
    // MARK: - Developer Mode State
    
    private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "developerModeEnabled")
            Log.info("Developer Mode: \(isEnabled ? "ENABLED" : "DISABLED")")
        }
    }
    
    // MARK: - Activation Mechanism
    
    private(set) var currentTapCount: Int = 0
    var showTapCount: Bool = false
    private var lastTapTime: Date = Date()
    private let requiredTaps: Int = 10
    private let tapTimeout: TimeInterval = 5.0 // Increased to 5 seconds
    
    private init() {
        // PRIVACY: Developer Mode must be impossible to enable in App Store Release —
        // no debug UI, no log export, no session-debug surface in production.
        #if DEBUG || INTERNAL_TOOLS
        self.isEnabled = UserDefaults.standard.bool(forKey: "developerModeEnabled")
        #else
        self.isEnabled = false
        #endif
    }
    
    // MARK: - Public API
    
    /// Register a tap on version label (call from SettingsView).
    /// Activation is a DEBUG/internal-only affordance — in Release the whole body is compiled
    /// out, so Developer Mode can never be turned on in production.
    func registerVersionTap() {
        #if DEBUG || INTERNAL_TOOLS
        let now = Date()

        // Reset counter if too much time passed
        if now.timeIntervalSince(lastTapTime) > tapTimeout {
            currentTapCount = 0
            showTapCount = false
        }

        currentTapCount += 1
        lastTapTime = now
        showTapCount = true // Show counter while tapping

        Log.info("Version tap: \(currentTapCount)/\(requiredTaps)")
        Log.debug("Version tap: \(currentTapCount)/\(requiredTaps)", category: "DeveloperMode")

        if currentTapCount >= requiredTaps {
            toggle()
            currentTapCount = 0

            // Hide counter after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showTapCount = false
            }
        }
        #endif
    }

    /// Toggle developer mode
    private func toggle() {
        isEnabled.toggle()
        
        Log.info("Developer Mode toggled: \(isEnabled ? "ENABLED" : "DISABLED")")
        
        // Haptic feedback (iOS only)
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        if isEnabled {
            generator.notificationOccurred(.success)
        } else {
            generator.notificationOccurred(.warning)
            Log.info("Developer Mode DISABLED")
        }
        #endif
    }
    
    /// Force disable (for security)
    func forceDisable() {
        isEnabled = false
        currentTapCount = 0
        showTapCount = false
    }
    
    // MARK: - Feature Flags
    //
    // All debug-surfacing flags are hard-false outside DEBUG/internal builds, independent of the
    // stored `isEnabled`, so no production code path can reveal debug UI even if the flag is set.

    /// Can user enable log collection?
    var canEnableLogCollection: Bool { debugGated }

    /// Can user view debug logs section?
    var showDebugLogsSection: Bool { debugGated }

    /// Can user export logs?
    var canExportLogs: Bool { debugGated }

    /// Show advanced session debugging?
    var showSessionDebugInfo: Bool { debugGated }

    private var debugGated: Bool {
        #if DEBUG || INTERNAL_TOOLS
        return isEnabled
        #else
        return false
        #endif
    }
}
