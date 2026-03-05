//
//  PushNotificationManager.swift
//  Construct Messenger
//
//  APNs Push Notifications Manager
//  Handles device token registration and push notification permissions
//

import Foundation
import UserNotifications
import UIKit

/// Manages Apple Push Notifications (APNs) integration
/// 
/// Responsibilities:
/// - Request push notification permissions
/// - Register device token with APNs and backend server
/// - Track permission status
/// - Provide observable state for UI
@MainActor
@Observable
class PushNotificationManager: NSObject {
    
    static let shared = PushNotificationManager()
    
    // MARK: - Published State
    
    /// Current push notification permission status
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    
    /// Whether push notifications are enabled (authorized + device token registered)
    private(set) var isPushEnabled: Bool = false
    
    /// Current device token (hex string)
    private(set) var deviceToken: String?

    /// Fires each time a silent push is received (for stream reconnection)
    private(set) var lastSilentPushDate: Date?

    func signalSilentPush() {
        lastSilentPushDate = Date()
    }
    
    // MARK: - Private Properties
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        // Set delegate for handling notifications
        notificationCenter.delegate = self
        
        // Check initial authorization status
        Task {
            await checkAuthorizationStatus()
        }
        
        Log.info("📱 PushNotificationManager initialized", category: "Push")
    }
    
    // MARK: - Public API
    
    /// Request push notification permission from user
    /// - Returns: Whether permission was granted
    @discardableResult
    func requestPermission() async -> Bool {
        Log.info("📱 Requesting push notification permission", category: "Push")
        
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            
            await checkAuthorizationStatus()
            
            if granted {
                Log.info("✅ Push notification permission granted", category: "Push")
                // Register for remote notifications on main thread
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                Log.info("❌ Push notification permission denied", category: "Push")
            }
            
            return granted
            
        } catch {
            Log.error("❌ Failed to request push notification permission: \(error)", category: "Push")
            return false
        }
    }
    
    /// Check current authorization status
    func checkAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        
        // Update isPushEnabled based on authorization and device token
        isPushEnabled = (authorizationStatus == .authorized || authorizationStatus == .provisional)
                        && deviceToken != nil
        
        Log.debug("📱 Push authorization status: \(authorizationStatus.description)", category: "Push")

        // If already authorized (e.g., after reinstall or app update), ensure APNs registration happens.
        await registerForRemoteNotificationsIfAuthorized()
    }

    private func registerForRemoteNotificationsIfAuthorized() async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        guard deviceToken == nil else { return }

        await MainActor.run {
            Log.info("📱 Registering for remote notifications (authorized, no token yet)", category: "Push")
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    /// Register device token with backend server
    /// Called from AppDelegate after APNs provides device token
    func registerDeviceToken(_ tokenData: Data) async {
        // Convert token to hex string
        let tokenString = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        
        Log.info("📱 Registering device token (length: \(tokenString.count))", category: "Push")
        
        // Save token locally
        self.deviceToken = tokenString
        
        // Register with backend server
        await registerWithServer(tokenString)
        
        // Update enabled status
        await checkAuthorizationStatus()
    }
    
    /// Unregister device token (e.g., on logout)
    func unregisterDeviceToken() async {
        guard let token = deviceToken else {
            Log.debug("📱 No device token to unregister", category: "Push")
            return
        }
        
        Log.info("📱 Unregistering device token", category: "Push")
        
        // Unregister from server
        await unregisterFromServer(token)
        
        // Clear local token
        self.deviceToken = nil
        self.isPushEnabled = false
    }
    
    /// Handle failed registration
    func handleRegistrationError(_ error: Error) {
        Log.error("❌ Failed to register for remote notifications: \(error)", category: "Push")
        isPushEnabled = false
    }
    
    // MARK: - Server Communication
    
    /// Register device token with backend server
    private func registerWithServer(_ token: String) async {
        do {
            Log.info("📡 Registering device token with server", category: "Push")
            
            let response = try await NotificationServiceClient.shared.registerDeviceToken(token: token)
            
            Log.info("✅ Device token registered with server: success=\(response.success)", category: "Push")
            
        } catch {
            Log.error("❌ Failed to register device token with server: \(error)", category: "Push")
            // Don't clear local token - we'll retry later
        }
    }
    
    /// Unregister device token from backend server
    private func unregisterFromServer(_ token: String) async {
        do {
            Log.info("📡 Unregistering device token from server", category: "Push")
            
            try await NotificationServiceClient.shared.unregisterDeviceToken(token: token)
            
            Log.info("✅ Device token unregistered from server", category: "Push")
            
        } catch {
            Log.error("❌ Failed to unregister device token from server: \(error)", category: "Push")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    
    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Log.debug("📱 Received notification while app in foreground", category: "Push")
        
        // For silent pushes (content-available), don't show anything
        let userInfo = notification.request.content.userInfo
        if userInfo["content-available"] as? Int == 1 {
            Log.debug("📱 Silent push - not showing notification", category: "Push")
            completionHandler([])
            return
        }
        
        // For visible pushes, show banner + sound + badge
        completionHandler([.banner, .sound, .badge])
    }
    
    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Log.info("📱 User tapped notification", category: "Push")
        
        let userInfo = response.notification.request.content.userInfo
        
        // Extract conversation_id if present
        if let conversationId = userInfo["conversation_id"] as? String {
            Log.info("📱 Opening conversation: \(conversationId)", category: "Push")
            // TODO: Navigate to conversation
            // NotificationCenter.default.post(
            //     name: .openConversation,
            //     object: nil,
            //     userInfo: ["conversationId": conversationId]
            // )
        }
        
        completionHandler()
    }
}

// MARK: - UNAuthorizationStatus Extension

extension UNAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
