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

    /// Local banner for a new incoming contact request (silent-push driven).
    /// Privacy-preserving: no sender id/name in the body — only a generic prompt
    /// to open Synaps. Collapses on a stable identifier so rapid retries don't spam.
    func showContactRequestReceivedNotification(requestId: String?, pendingCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("construct_app_name", comment: "App name")
        if pendingCount > 1 {
            content.body = String(
                format: NSLocalizedString("contact_request_received_body_plural", comment: ""),
                pendingCount
            )
        } else {
            content.body = NSLocalizedString("contact_request_received_body", comment: "")
        }
        content.sound = .default
        content.userInfo = [
            "type": "contactRequestReceived",
            "requestId": requestId ?? "",
        ]

        let identifier = requestId.map { "cr-recv-\($0)" } ?? "cr-recv-\(UUID().uuidString)"
        post(content, identifier: identifier, coveredByPushOf: "contact_request_received")
    }

    /// Takes back the "New message" push banners when the fetch they woke found nothing new to
    /// read (`PushBannerReplacement.bannersToWithdraw`).
    func withdrawPushBannersIfNothingNew(somethingNew: Bool, deliveredBefore cutoff: Date) {
        notificationCenter.getDeliveredNotifications { [notificationCenter] delivered in
            let ids = PushBannerReplacement.bannersToWithdraw(
                among: delivered.map(PushBannerReplacement.Delivered.init),
                somethingNew: somethingNew,
                deliveredBefore: cutoff
            )
            guard !ids.isEmpty else { return }
            notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
            Log.info("Withdrew \(ids.count) push banner(s): the push brought nothing to read", category: "LocalNotifications")
        }
    }

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
        post(content, identifier: identifier, coveredByPushOf: "new_message")
    }

    /// Posts `content`, unless the server's push banner for this message is already on screen.
    ///
    /// Since 2026-10-05 a message push is an alert ("Konstruct / New message", from the app's
    /// own strings) that also carries `content-available`. iOS shows that banner the moment the
    /// push lands; when it grants the wake, the fetch arrives here a fraction of a second later.
    /// Replacing the banner (remove it, post ours silently) put two banners on screen in a row
    /// for one message — the server's log and the device's agreed on 2026-10-05. So when a push
    /// banner of the same kind was delivered moments ago, it stays and nothing is posted.
    /// The cost: that banner opens the app, not the chat — a blind push names no conversation.
    private func post(_ content: UNMutableNotificationContent, identifier: String, coveredByPushOf activity: String) {
        notificationCenter.getDeliveredNotifications { [notificationCenter] delivered in
            let covering = PushBannerReplacement.coveringPushBanners(
                among: delivered.map(PushBannerReplacement.Delivered.init),
                activity: activity,
                now: Date()
            )
            if !covering.isEmpty {
                Log.debug("Notification skipped: \(identifier) (push banner already shown)", category: "LocalNotifications")
                return
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            notificationCenter.add(request) { error in
                if let error {
                    Log.error("Failed to show notification: \(error)", category: "LocalNotifications")
                } else {
                    Log.debug("Notification shown: \(identifier)", category: "LocalNotifications")
                }
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

    /// Set the icon badge to the unread messages in the store. The one way the badge is set:
    /// until 2026-10-19 nothing set it above zero — `updateBadge` had no caller, the server's push
    /// carries no badge, and every foreground and every opened chat cleared it — so a person
    /// could not tell from the icon whether anything was waiting (testers).
    /// Called on foreground, on leaving it, after a push-woken fetch and when unread changes.
    func syncBadge() {
        Task { await syncBadgeNow() }
    }

    /// `syncBadge()` for a caller that must not return before the badge is set: a push-woken
    /// fetch, after which iOS may suspend the process before a detached task runs.
    @MainActor
    func syncBadgeNow() async {
        // A store that cannot be read leaves the badge as it is rather than zeroing it.
        guard let chats = try? LocalRepositories.chats.chats() else { return }
        let count = BadgeCount.total(chats.map(\.unreadCount))
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        Log.debug("Badge set to \(count)", category: "LocalNotifications")
    }

    // MARK: - Notification Management

    /// Remove all delivered notifications
    func removeAllNotifications() {
        notificationCenter.removeAllDeliveredNotifications()
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

            case "contactRequestReceived":
                // Switch to Synaps and refresh the requests inbox.
                NotificationCenter.default.post(name: .openSynapsTab, object: nil)
                NotificationCenter.default.post(name: .contactRequestReceived, object: nil, userInfo: userInfo)

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
    /// Fired when a silent push with `activity_type = contact_request_received` arrives
    /// (or after a background inbox refresh). Synaps should reload the requests list.
    static let contactRequestReceived = Notification.Name("com.construct.contactRequestReceived")
    /// Switch UI to the Synaps tab (e.g. after tapping a contact-request local notification).
    static let openSynapsTab = Notification.Name("com.construct.openSynapsTab")
}

// MARK: - Localization Helpers

private extension String {
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}

/// How many unread each chat had when the app was last left. Unread above that is something the
/// person has not seen, and a push banner may be its only sign; unread at or below it they saw.
/// The icon badge's number. Pure, so a test reaches it without a notification center.
enum BadgeCount {
    static func total(_ unreadByChat: [Int]) -> Int {
        unreadByChat.reduce(0) { $0 + max($1, 0) }
    }
}

enum UnreadSeen {
    private static let key = "construct.notifications.unreadSeen"

    static func record(_ counts: [String: Int], in defaults: UserDefaults = .standard) {
        defaults.set(counts.filter { $0.value > 0 }, forKey: key)
    }

    /// Nil before the first record: then every unread counts as new, which keeps every banner.
    static func load(from defaults: UserDefaults = .standard) -> [String: Int]? {
        defaults.dictionary(forKey: key) as? [String: Int]
    }

    static func somethingNew(seen: [String: Int]?, now: [String: Int]) -> Bool {
        now.contains { chat, unread in unread > (seen?[chat] ?? 0) }
    }
}

/// Which push banners already cover a banner of our own. Pure, so the window and the kind match
/// are reachable from tests without a notification center.
enum PushBannerReplacement {

    /// How recent a push banner must be to count as this wake's. A wake runs within ~30 s of
    /// its push; an older banner belongs to an earlier message, so ours is posted (with its
    /// sound, since nothing else just made one).
    static let window: TimeInterval = 60

    struct Delivered: Equatable {
        let identifier: String
        let date: Date
        let fromPush: Bool
        /// `construct.type` from the push payload.
        let activity: String?

        init(identifier: String, date: Date, fromPush: Bool, activity: String?) {
            self.identifier = identifier
            self.date = date
            self.fromPush = fromPush
            self.activity = activity
        }

        init(_ notification: UNNotification) {
            let construct = notification.request.content.userInfo["construct"] as? [AnyHashable: Any]
            self.init(
                identifier: notification.request.identifier,
                date: notification.date,
                fromPush: notification.request.trigger is UNPushNotificationTrigger,
                activity: construct?["type"] as? String
            )
        }
    }

    /// The push banners to take back after a push-woken fetch: every "New message" push banner
    /// delivered before the fetch began, when nothing new is waiting to be read. The server
    /// cannot tell a delivery receipt from a message — on purpose,
    /// `decisions/sealed-content-type-inside-the-plaintext-frame` — so a receipt arrives with the
    /// same banner, and opening it found nothing (TODO 123, 2026-10-06).
    ///
    /// "New" is unread that grew since the app was last left (`UnreadSeen`), not unread at all.
    /// A real message's banner is the push's own — ours is not posted beside it, see `post` — so
    /// it must stay while that message is unread; but until 2026-10-17 any unread chat kept every
    /// banner, and one old unread chat is the usual state, so receipts kept their banners almost
    /// always. A banner delivered after the fetch began may be for a message it did not see.
    static func bannersToWithdraw(among delivered: [Delivered], somethingNew: Bool, deliveredBefore cutoff: Date) -> [String] {
        guard !somethingNew else { return [] }
        return delivered
            .filter { $0.fromPush && $0.activity == "new_message" && $0.date <= cutoff }
            .map(\.identifier)
    }

    static func coveringPushBanners(among delivered: [Delivered], activity: String, now: Date) -> [String] {
        delivered
            .filter { $0.fromPush && $0.activity == activity && now.timeIntervalSince($0.date) <= window }
            .map(\.identifier)
    }
}
