//
//  DeveloperMode.swift
//  ConstructMessenger
//
//  Hidden developer mode for internal debugging
//  Activation: Tap app version 10 times in Settings
//

import Foundation
import UIKit

@Observable
class DeveloperMode {
    static let shared = DeveloperMode()
    
    // MARK: - Developer Mode State
    
    private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "developerModeEnabled")
            Log.info("🔧 Developer Mode: \(isEnabled ? "ENABLED" : "DISABLED")")
        }
    }
    
    // MARK: - Activation Mechanism
    
    private(set) var currentTapCount: Int = 0
    var showTapCount: Bool = false
    private var lastTapTime: Date = Date()
    private let requiredTaps: Int = 10
    private let tapTimeout: TimeInterval = 5.0 // Increased to 5 seconds
    
    private init() {
        // ✅ TEMPORARY: Always enable for QR debugging
        self.isEnabled = true
        UserDefaults.standard.set(true, forKey: "developerModeEnabled")
        Log.info("🔧 Developer Mode: FORCE ENABLED for debugging")
    }
    
    // MARK: - Public API
    
    /// Register a tap on version label (call from SettingsView)
    func registerVersionTap() {
        let now = Date()
        
        // Reset counter if too much time passed
        if now.timeIntervalSince(lastTapTime) > tapTimeout {
            currentTapCount = 0
            showTapCount = false
        }
        
        currentTapCount += 1
        lastTapTime = now
        showTapCount = true // Show counter while tapping
        
        print("🔧 Version tap: \(currentTapCount)/\(requiredTaps)")
        Log.debug("Version tap: \(currentTapCount)/\(requiredTaps)", category: "DeveloperMode")
        
        if currentTapCount >= requiredTaps {
            toggle()
            currentTapCount = 0
            
            // Hide counter after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showTapCount = false
            }
        }
    }
    
    /// Toggle developer mode
    private func toggle() {
        isEnabled.toggle()
        
        print("🔧 Developer Mode toggled: \(isEnabled ? "ENABLED ✅" : "DISABLED ❌")")
        
        // Haptic feedback (iOS only)
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        if isEnabled {
            generator.notificationOccurred(.success)
        } else {
            generator.notificationOccurred(.warning)
            print("❌ Developer Mode DISABLED")
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
    
    /// Can user enable log collection?
    var canEnableLogCollection: Bool {
        return isEnabled
    }
    
    /// Can user view debug logs section?
    var showDebugLogsSection: Bool {
        return isEnabled
    }
    
    /// Can user export logs?
    var canExportLogs: Bool {
        return isEnabled
    }
    
    /// Show advanced session debugging?
    var showSessionDebugInfo: Bool {
        return isEnabled
    }
}
