//
//  PushNotificationManager.swift
//  Construct Messenger
//
//  APNs Push Notifications Manager
//  Handles device token registration and push notification permissions
//

#if os(iOS)
import Foundation
import UserNotifications
import UIKit
import GRPCCore

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

    /// Whether the current token has been successfully registered with the server.
    /// Resets when a new token arrives or when the user logs out.
    private(set) var isRegisteredWithServer: Bool = false

    func signalSilentPush() {
        lastSilentPushDate = Date()
    }
    
    // MARK: - Private Properties
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private var sessionObserverTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        // Set delegate for handling notifications
        notificationCenter.delegate = self
        
        // Check initial authorization status
        Task {
            await checkAuthorizationStatus()
        }

        // Retry device token registration once a session becomes available.
        // APNs often delivers the token before the user is authenticated, so the
        // first registerWithServer attempt fails silently. This observer re-fires
        // whenever sessionToken becomes non-nil and the token isn't yet registered.
        sessionObserverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = SessionManager.shared.sessionToken
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                await self.retryServerRegistrationIfNeeded()
            }
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
        
        isPushEnabled = (authorizationStatus == .authorized || authorizationStatus == .provisional)
                        && deviceToken != nil
        
        Log.debug("📱 Push authorization status: \(authorizationStatus.description)", category: "Push")

        await registerForRemoteNotificationsIfAuthorized()

        if authorizationStatus == .notDetermined && SessionManager.shared.sessionToken != nil {
            Log.info("📱 Permission not yet requested but user is authenticated — requesting now", category: "Push")
            await requestPermission()
        }
    }

    private func registerForRemoteNotificationsIfAuthorized() async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        // Apple recommends calling registerForRemoteNotifications() on every launch.
        // APNs returns the same token if unchanged (no-op), or a new one if rotated
        // (e.g. after reinstall). In either case registerDeviceToken() will handle it.
        await MainActor.run {
            Log.info("📱 Requesting APNs token (re-register on every launch)", category: "Push")
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    /// Register device token with backend server
    /// Called from AppDelegate after APNs provides device token
    func registerDeviceToken(_ tokenData: Data) async {
        let tokenString = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        Log.info("📱 Registering device token (length: \(tokenString.count))", category: "Push")

        // New token from APNs — mark as not yet registered with server
        if deviceToken != tokenString {
            isRegisteredWithServer = false
        }
        self.deviceToken = tokenString

        // Register with backend server (may fail if user not authenticated yet)
        await registerWithServer(tokenString)

        // APNs delivered a token → authorization is confirmed. Set isPushEnabled directly
        // instead of calling checkAuthorizationStatus(), which would call
        // registerForRemoteNotifications() again and create an infinite loop:
        // registerDeviceToken → checkAuthorizationStatus → registerForRemoteNotifications
        // → APNs callback → registerDeviceToken → …
        isPushEnabled = true
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
        self.isRegisteredWithServer = false
    }
    
    /// Handle failed registration
    func handleRegistrationError(_ error: Error) {
        Log.error("❌ Failed to register for remote notifications: \(error)", category: "Push")
        isPushEnabled = false
    }
    
    // MARK: - Server Communication

    /// Public entry point: ensure the current token is registered with the server.
    /// Call this after login and on every foreground transition so the DB record is
    /// always current even if a previous attempt failed or the server DB was cleared.
    func ensureTokenRegistered() async {
        // If we don't have a token yet, ask APNs for one.
        // APNs will call didRegisterForRemoteNotificationsWithDeviceToken which
        // calls registerDeviceToken(_:) → registerWithServer.
        guard let token = deviceToken else {
            Log.info("📱 ensureTokenRegistered — no token, requesting from APNs", category: "Push")
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            return
        }
        // Token exists but not yet confirmed on server (e.g. previous attempt failed,
        // app reinstalled, or server DB was cleared).
        if !isRegisteredWithServer {
            Log.info("🔄 ensureTokenRegistered — token exists but not on server, retrying", category: "Push")
            await registerWithServer(token)
        }
    }

    /// Retry registering with the server if we have a token but haven't succeeded yet.
    /// Called whenever SessionManager.sessionToken changes to non-nil.
    private func retryServerRegistrationIfNeeded() async {
        guard SessionManager.shared.sessionToken != nil else { return }
        guard let token = deviceToken, !isRegisteredWithServer else { return }
        Log.info("🔄 Retrying device token registration (session now available)", category: "Push")
        await registerWithServer(token)
    }
    
    /// Register device token with backend server
    private func registerWithServer(_ token: String) async {
        guard SessionManager.shared.sessionToken != nil else {
            Log.info("⏸️ Device token registration deferred — no session yet", category: "Push")
            return
        }
        for attempt in 0..<3 {
            do {
                Log.info("📡 Registering device token with server", category: "Push")
                let response = try await NotificationServiceClient.shared.registerDeviceToken(token: token)
                isRegisteredWithServer = true
                Log.info("✅ Device token registered with server: success=\(response.success)", category: "Push")
                return
            } catch {
                let shouldRetry: Bool
                if let rpcError = error as? RPCError {
                    shouldRetry = rpcError.code == .unavailable || rpcError.code == .deadlineExceeded
                } else {
                    shouldRetry = false
                }
                if shouldRetry && attempt < 2 {
                    let delay = Double(attempt + 1) * 2.0
                    Log.info("🔄 Push token registration failed (attempt \(attempt + 1)/3), retrying in \(Int(delay))s", category: "Push")
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    Log.error("❌ Failed to register device token with server: \(error)", category: "Push")
                    return
                }
            }
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
    
    /// Handle notification when app is in foreground.
    ///
    /// The server sends APNs *alert* pushes whose body contains the raw
    /// encrypted message payload (KNST1:… format). We must never display
    /// that raw ciphertext to the user. Instead:
    ///   - Silent push (content-available only)  → suppress (app handles it)
    ///   - APNs alert push with encrypted body   → cancel raw push,
    ///                                             schedule a clean local banner
    ///   - Local notification (from our own code) → show as-is
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let construct = userInfo["construct"] as? [AnyHashable: Any]

        // Silent push — wake the app but don't show a banner; our
        // didReceiveRemoteNotification handler fetches messages and posts
        // its own local notification.
        if aps?["content-available"] as? Int == 1 && aps?["alert"] == nil {
            Log.debug("📱 Silent push received in foreground — suppressed", category: "Push")
            completionHandler([])
            return
        }

        // APNs alert push (UNPushNotificationTrigger) — the server body may
        // contain raw ciphertext. Replace with a privacy-safe local notification.
        if notification.request.trigger is UNPushNotificationTrigger {
            Log.debug("📱 APNs alert push in foreground — replacing with local banner", category: "Push")
            let chatId = construct?["conversation_id"] as? String
            LocalNotificationManager.shared.showNewMessageNotification(chatId: chatId)
            completionHandler([])   // suppress the raw push
            return
        }

        // Local notification (scheduled by our own code) — show it.
        Log.debug("📱 Local notification in foreground — showing", category: "Push")
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    
    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Log.info("📱 User tapped notification", category: "Push")
        
        let userInfo = response.notification.request.content.userInfo
        
        if let conversationId = userInfo["conversation_id"] as? String {
            Log.info("📱 Opening conversation: \(conversationId)", category: "Push")
            Task { @MainActor in
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                    appDelegate.deepLinkHandler.deepLink = .openChat(chatId: conversationId)
                }
            }
        }
        
        completionHandler()
    }
}

// MARK: - UNAuthorizationStatus Extension

#else
// macOS native app uses different push delivery mechanism (or polling via stream).
// PushNotificationManager is a no-op on macOS.
import Foundation
import UserNotifications

final class PushNotificationManager {
    static let shared = PushNotificationManager()
    private init() {}
    // On macOS, push is delivered via persistent gRPC MessageStream — no APNs needed.
    var isPushEnabled: Bool { true }
    var lastSilentPushDate: Date? { nil }
    var authorizationStatus: UNAuthorizationStatus { .authorized }
    var deviceToken: String? { nil }
    var isRegisteredWithServer: Bool { true }
    func registerIfNeeded() {}
    func updateToken(_ token: Data) {}
    func signalSilentPush() {}
    func ensureTokenRegistered() async {}
    func registerDeviceToken(_ tokenData: Data) async {}
    func unregisterDeviceToken() async {}
    func handleRegistrationError(_ error: Error) {}
    func requestPermission() async -> Bool { true }
    func checkAuthorizationStatus() async {}
}
#endif

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
