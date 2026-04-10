//
//  InAppNotificationService.swift
//  Construct Messenger
//
//  Fires local notification banners for incoming messages in non-active chats.
//
//  Flow:
//    MessageRouter.saveMessage() → InAppNotificationService.handle(...)
//    → skipped if chat is muted or currently open
//    → skipped if app is backgrounded (APNs silent push handles that path)
//    → fires UNNotificationRequest immediately (shows as banner while in-app)
//
//  Active chat tracking:
//    ChatViewModel calls activeChatId = chat.id  on appear
//    ChatViewModel calls activeChatId = nil       on disappear
//

import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class InAppNotificationService {

    static let shared = InAppNotificationService()

    // MARK: - Active chat

    /// Set by ChatViewModel to suppress banners for the currently open conversation.
    var activeChatId: String? = nil

    /// Instance ID of the ChatViewModel that last registered as active.
    /// Prevents a SwiftUI-diffing copy of ChatViewModel from clearing the
    /// activeChatId that was set by the "real" retained ViewModel.
    private var activeChatOwnerID: UUID? = nil

    /// Register the current chat as active. Only the most recently registered
    /// instance (by ownerID) may later clear it.
    func registerActiveChat(_ chatId: String, ownerID: UUID) {
        activeChatId = chatId
        activeChatOwnerID = ownerID
    }

    /// Deregister the active chat. No-op if `ownerID` is not the current owner
    /// (i.e., a stale SwiftUI-diffing copy tried to clear it).
    func unregisterActiveChat(ownerID: UUID) {
        guard activeChatOwnerID == ownerID else { return }
        activeChatId = nil
        activeChatOwnerID = nil
    }

    // MARK: - Incoming message

    /// Called from MessageRouter after saving an incoming message.
    /// Privacy: always generic text — no sender name, no content preview.
    func handle(chatId: String, isMuted: Bool, senderName: String, preview: String) {
        guard !isMuted else { return }
        guard chatId != activeChatId else { return }

        LocalNotificationManager.shared.showNewMessageNotification(chatId: chatId)
    }

    // MARK: - Flood alert

    /// Called when the burst detector fires for the first time for a sender.
    /// Privacy: generic title — no sender name exposed in notification.
    func handleFloodAlert(chatId: String, senderName: String, messageCount: Int) {
        guard chatId != activeChatId else { return }

        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("construct_app_name", comment: "")
        content.body  = String(format: NSLocalizedString("flood_alert_body", comment: ""), messageCount)
        content.sound = .defaultCritical
        content.userInfo = ["chatID": chatId, "floodAlert": true]

        let request = UNNotificationRequest(
            identifier: "flood-\(chatId)",   // stable ID → replaces previous flood alert for same chat
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("❌ InAppNotification: flood alert failed — \(error)", category: "Notifications")
            }
        }
    }
}
