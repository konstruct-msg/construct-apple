//
//  AppDelegate.swift
//  Construct Messenger
//
//  Created by Claude on 03.01.2026.
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
        let userDefaults = UserDefaults.standard
        let isBackgroundFetchEnabled = userDefaults.bool(forKey: "backgroundFetchEnabled")

        if isBackgroundFetchEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
            Log.info("Background fetch is enabled, scheduled first task")
        } else {
            Log.info("Background fetch is disabled by user")
        }

        // Initialize local notification manager
        // This ensures it's ready when needed
        _ = LocalNotificationManager.shared

        return true
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
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Log.debug("Application did enter background")

        // Ensure background fetch is scheduled if enabled
        let userDefaults = UserDefaults.standard
        let isBackgroundFetchEnabled = userDefaults.bool(forKey: "backgroundFetchEnabled")

        if isBackgroundFetchEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
        }
    }
}
