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

    // MARK: - Incoming message

    /// Called from MessageRouter after saving an incoming message.
    /// Shows a local notification banner only when:
    ///   - App is foregrounded (backgrounded → APNs covers it)
    ///   - The message is NOT in the currently visible chat
    ///   - The chat is NOT muted
    func handle(chatId: String, isMuted: Bool, senderName: String, preview: String) {
        guard !isMuted else { return }
        guard chatId != activeChatId else { return }

        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif

        let content = UNMutableNotificationContent()
        content.title = senderName.isEmpty ? "New Message" : senderName
        content.body = preview.isEmpty ? "New message" : String(preview.prefix(120))
        content.sound = .default
        content.userInfo = ["chatID": chatId]

        let request = UNNotificationRequest(
            identifier: "inapp-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("❌ InAppNotification: failed to schedule — \(error)", category: "Notifications")
            }
        }
    }
}
