//
//  LocalNotificationManager.swift
//  Construct Messenger
//
//

import Combine
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Manages local notifications for background message delivery
/// Shows user-friendly notifications when messages arrive in background
class LocalNotificationManager: NSObject {

    // MARK: - Properties

    static let shared = LocalNotificationManager()

    private let notificationCenter = UNUserNotificationCenter.current()

    /// Indicates if notification permission has been granted
    @Published private(set) var isAuthorized = false

    // MARK: - Initialization

    private override init() {
        super.init()
        // Note: UNUserNotificationCenterDelegate is handled by PushNotificationManager
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    /// Request notification authorization from user
    /// Call this when user wants to enable notifications
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted

                if let error = error {
                    Log.error("Notification authorization error: \(error)")
                }

                Log.info("Notification authorization: \(granted ? "granted" : "denied")")
                completion(granted)
            }
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() {
        notificationCenter.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
                Log.debug("Notification authorization status: \(settings.authorizationStatus.rawValue)")
            }
        }
    }

    /// Get detailed notification settings
    func getNotificationSettings(completion: @escaping (UNNotificationSettings) -> Void) {
        notificationCenter.getNotificationSettings(completionHandler: completion)
    }

    // MARK: - Show Notifications

    /// Show a generic "New Message" notification.
    /// No sender name or content is included to preserve E2E privacy.
    /// - Parameter chatId: Used to collapse repeat notifications for the same chat.
    ///                     If nil, a unique identifier is generated (no collapsing).
    func showNewMessageNotification(chatId: String? = nil) {
        // Do NOT guard on cached isAuthorized — it starts as false and is set
        // asynchronously, causing race conditions during background wakeup.
        // UNUserNotificationCenter silently drops the request if not authorized.

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("construct_app_name", comment: "App name")
        content.body = NSLocalizedString("construct_new_message", comment: "New message")
        content.sound = .default
        content.badge = NSNumber(value: 1)
        content.userInfo = ["type": "newMessage"]

        // Use a stable per-chat identifier so back-to-back messages in the same
        // conversation collapse to a single banner instead of spamming the lock screen.
        let identifier = chatId.map { "msg-chat-\($0)" } ?? "msg-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                Log.error("Failed to show notification: \(error)", category: "LocalNotifications")
            } else {
                Log.debug("Notification shown: \(identifier)", category: "LocalNotifications")
            }
        }
    }

    /// Show notification for multiple new messages
    /// - Parameters:
    ///   - messageCount: Number of new messages
    ///   - fromContacts: Number of different contacts (optional)
    func showMultipleMessagesNotification(messageCount: Int, fromContacts: Int? = nil) {
        // No isAuthorized guard — let UNUserNotificationCenter handle authorization

        let content = UNMutableNotificationContent()
        content.title = "construct_new_messages".localized // "New Messages"

        if let contacts = fromContacts, contacts > 1 {
            content.body = String(
                format: "construct_new_messages_from_contacts".localized,
                messageCount,
                contacts
            ) // "You have %d new messages from %d contacts"
        } else {
            content.body = String(
                format: "construct_new_messages_count".localized,
                messageCount
            ) // "You have %d new messages"
        }

        content.sound = .default
        content.badge = NSNumber(value: messageCount)
        content.userInfo = ["type": "multipleMessages"]

        let identifier = "messages-batch-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                Log.error("Failed to show batch notification: \(error)")
            }
        }
    }

    /// Show notification for background sync completion
    func showSyncCompletedNotification(newMessagesCount: Int) {
        guard newMessagesCount > 0 else { return }
        // No isAuthorized guard — let UNUserNotificationCenter handle authorization

        let content = UNMutableNotificationContent()
        content.title = "construct_sync_completed".localized // "Messages Synced"
        content.body = String(
            format: "construct_sync_completed_count".localized,
            newMessagesCount
        ) // "Synced %d new messages"
        content.sound = nil // Silent notification
        content.badge = NSNumber(value: newMessagesCount)

        let identifier = "sync-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { _ in }
    }

    // MARK: - Badge Management

    /// Update app badge number
    func updateBadge(_ count: Int) {
        Task { @MainActor in
            // iOS 16+ uses UNUserNotificationCenter.setBadgeCount
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(count)
            } else {
                #if canImport(UIKit)
                UIApplication.shared.applicationIconBadgeNumber = count
                #endif
            }
            Log.debug("📛 Badge updated to \(count)", category: "LocalNotifications")
        }
    }

    /// Clear app badge
    func clearBadge() {
        Task { @MainActor in
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            } else {
                #if canImport(UIKit)
                UIApplication.shared.applicationIconBadgeNumber = 0
                #endif
            }
            Log.debug("📛 Badge cleared", category: "LocalNotifications")
        }
    }

    // MARK: - Notification Management

    /// Remove all delivered notifications
    func removeAllNotifications() {
        notificationCenter.removeAllDeliveredNotifications()
        clearBadge()
    }

    /// Remove notification with specific identifier
    func removeNotification(identifier: String) {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Get all pending notification requests
    func getPendingNotifications(completion: @escaping ([UNNotificationRequest]) -> Void) {
        notificationCenter.getPendingNotificationRequests(completionHandler: completion)
    }

    /// Get all delivered notifications
    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) {
        notificationCenter.getDeliveredNotifications(completionHandler: completion)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LocalNotificationManager: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        // User can see banner and hear sound
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Log.debug("Notification tapped: \(userInfo)")

        // Handle different notification types
        if let type = userInfo["type"] as? String {
            switch type {
            case "newMessage":
                if let chatID = userInfo["chatID"] as? String {
                    handleOpenChat(chatID: chatID)
                }

            case "multipleMessages":
                handleOpenChats()

            default:
                break
            }
        }

        completionHandler()
    }

    // MARK: - Deep Linking

    /// Handle opening specific chat
    private func handleOpenChat(chatID: String) {
        // TODO: Implement deep linking to specific chat
        // Post notification for ContentView to handle navigation
        NotificationCenter.default.post(
            name: .openChat,
            object: nil,
            userInfo: ["chatID": chatID]
        )

        Log.debug("Opening chat: \(chatID)")
    }

    /// Handle opening chats list
    private func handleOpenChats() {
        // TODO: Implement navigation to chats list
        NotificationCenter.default.post(
            name: .openChatsList,
            object: nil
        )

        Log.debug("Opening chats list")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openChat = Notification.Name("com.construct.openChat")
    static let openChatsList = Notification.Name("com.construct.openChatsList")
    /// Fired when a silent push with `activity_type = contact_request_accepted` arrives.
    /// `userInfo["requestId"]` carries the request_id string from the server.
    static let contactRequestAccepted = Notification.Name("com.construct.contactRequestAccepted")
}

// MARK: - Localization Helpers

private extension String {
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}
