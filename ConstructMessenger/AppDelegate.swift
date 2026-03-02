//
//  AppDelegate.swift
//  Construct Messenger
//
//

import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {

    // Inject DeepLinkHandler for processing Universal Links
    let deepLinkHandler = DeepLinkHandler()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        Log.info("Application did finish launching")

        // CRITICAL: Register background tasks BEFORE app finishes launching
        // This must be done early in the launch process
        BackgroundFetchManager.shared.registerBackgroundTasks()

        // Check if user has enabled background fetch in settings
        // If enabled, schedule the first background fetch task
        if BackgroundFetchConfig.shouldBeEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
            Log.info("Background fetch is enabled, scheduled first task")
        } else {
            Log.info("Background fetch is disabled by user or Low Power Mode")
        }

        // Initialize local notification manager
        // This ensures it's ready when needed
        _ = LocalNotificationManager.shared
        
        // ✅ NEW: Initialize push notification manager
        // This sets up the UNUserNotificationCenter delegate
        _ = PushNotificationManager.shared

        // NOTE: NetworkReachabilityManager and MessageQueueManager will be initialized
        // lazily when first accessed. This avoids potential circular dependencies
        // and initialization issues at app startup.

        return true
    }
    
    // MARK: - Push Notifications
    
    /// Called when APNs successfully registers device token
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Log.info("📱 Received device token from APNs", category: "Push")
        
        // Register token with backend server
        Task {
            await PushNotificationManager.shared.registerDeviceToken(deviceToken)
        }
    }
    
    /// Called when APNs fails to register device token
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.error("📱 Failed to register for remote notifications: \(error)", category: "Push")
        PushNotificationManager.shared.handleRegistrationError(error)
    }

    // MARK: - Silent Push (background wakeup)

    /// Called when a silent push arrives (content-available: 1).
    /// Server sends this when a new message is waiting. We wake up, trigger
    /// stream reconnect to fetch pending messages, then call the completion handler.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Log.info("📱 Silent push received: \(userInfo["type"] ?? "unknown")", category: "Push")

        // Signal ChatsViewModel to reconnect the stream and pick up pending messages
        NotificationCenter.default.post(name: .silentPushReceived, object: nil)

        // Give the stream up to 25s to connect and fetch (system limit is 30s)
        Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            completionHandler(.newData)
        }
    }

    // MARK: - Universal Links
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            Log.info("AppDelegate: Not a web browsing activity or no URL")
            return false
        }

        Log.info("AppDelegate: Received Universal Link: \(url.absoluteString)", category: "DeepLink")
        let result = deepLinkHandler.handleURL(url)
        Log.info("AppDelegate: Deep link handling result: \(result)", category: "DeepLink")
        return result
    }
    
    // MARK: - Custom URL Scheme (konstruct://)
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey : Any] = [:]
    ) -> Bool {
        Log.info("AppDelegate: Received URL Scheme: \(url.absoluteString)", category: "DeepLink")
        let result = deepLinkHandler.handleURL(url)
        Log.info("AppDelegate: URL Scheme handling result: \(result)", category: "DeepLink")
        return result
    }

    // MARK: - Scene Lifecycle (iOS 13+)

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    // MARK: - Application Lifecycle

    func applicationWillTerminate(_ application: UIApplication) {
        Log.info("Application will terminate")

        // Cancel all scheduled background tasks if user has disabled them
        let userDefaults = UserDefaults.standard
        let isBackgroundFetchEnabled = userDefaults.bool(forKey: "backgroundFetchEnabled")

        if !isBackgroundFetchEnabled {
            BackgroundFetchManager.shared.cancelAllBackgroundTasks()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.debug("Application did become active")

        // Clear badge when app becomes active
        LocalNotificationManager.shared.clearBadge()

        // Remove all delivered notifications
        LocalNotificationManager.shared.removeAllNotifications()

        // Refresh push authorization state and re-register if needed
        Task { await PushNotificationManager.shared.checkAuthorizationStatus() }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Log.debug("Application did enter background")

        // Ensure background fetch is scheduled if enabled
        if BackgroundFetchConfig.shouldBeEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
        } else {
            BackgroundFetchManager.shared.cancelAllBackgroundTasks()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a silent APNs push arrives — ChatsViewModel reconnects the stream.
    static let silentPushReceived = Notification.Name("com.construct.silentPushReceived")
}
