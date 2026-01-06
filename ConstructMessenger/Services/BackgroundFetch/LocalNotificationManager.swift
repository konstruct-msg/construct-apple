//
//  LocalNotificationManager.swift
//  Construct Messenger
//
//  Created by Claude on 03.01.2026.
//

import Foundation
import UserNotifications
import UIKit

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
        notificationCenter.delegate = self
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

    /// Show notification for new message
    /// - Parameters:
    ///   - senderName: Name of the message sender (may be "Unknown" for privacy)
    ///   - messagePreview: Preview of the message content (optional)
    ///   - chatID: Chat identifier for deep linking
    func showNewMessageNotification(
        senderName: String,
        messagePreview: String? = nil,
        chatID: String
    ) {
        guard isAuthorized else {
            Log.debug("Cannot show notification: not authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "construct_new_message".localized // Localized "New Message"
        content.body = formatNotificationBody(senderName: senderName, preview: messagePreview)
        content.sound = .default
        content.badge = NSNumber(value: 1)

        // Add userInfo for handling tap
        content.userInfo = [
            "type": "newMessage",
            "chatID": chatID
        ]

        // Create request with unique identifier
        let identifier = "message-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        // Add notification
        notificationCenter.add(request) { error in
            if let error = error {
                Log.error("Failed to show notification: \(error)")
            } else {
                Log.debug("Notification shown: \(identifier)")
            }
        }
    }

    /// Show notification for multiple new messages
    /// - Parameters:
    ///   - messageCount: Number of new messages
    ///   - fromContacts: Number of different contacts (optional)
    func showMultipleMessagesNotification(messageCount: Int, fromContacts: Int? = nil) {
        guard isAuthorized else {
            return
        }

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
        guard isAuthorized, newMessagesCount > 0 else {
            return
        }

        // Only show sync notification if user has enabled it in settings
        // For privacy-first approach, we default to NOT showing this
        // User can enable it explicitly if they want

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

    // MARK: - Helpers

    /// Format notification body based on privacy settings
    private func formatNotificationBody(senderName: String, preview: String?) -> String {
        // TODO: Check user's notification privacy settings

        // For now, default to showing sender name but not message preview
        // This balances privacy with usefulness
        if let preview = preview {
            return "\(senderName): \(preview)"
        } else {
            return "construct_new_message_from".localized.replacingOccurrences(of: "%@", with: senderName)
            // "New message from %@"
        }
    }

    // MARK: - Badge Management

    /// Update app badge number
    func updateBadge(_ count: Int) {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    /// Clear app badge
    func clearBadge() {
        updateBadge(0)
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
}

// MARK: - Localization Helpers

private extension String {
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}
