//
//  InAppNotificationService.swift
//  Construct Messenger
//
//  Fires local notification banners for incoming messages in non-active chats.
//
//  Flow:
//    MessageRouter.saveMessage() → InAppNotificationService.handle(...)
//    → skipped if chat is muted
//    → skipped if the chat is VISIBLE (open AND app on screen — see isChatVisible)
//    → fires UNNotificationRequest immediately
//
//  Ownership: whichever path actually SAVES a message posts its notification — this one for
//  the MessageStream, BackgroundFetchManager for its own fetch. Saving is deduplicated
//  (PersistentACKStore + the "already saved" check in MessageRouter), so a message yields
//  exactly one banner regardless of which path won the race. This file must therefore NOT
//  bail out just because the app is backgrounded: a silent push wakes both paths, and the
//  stream frequently wins, in which case nobody else would notify.
//
//  Active chat tracking:
//    ChatViewModel calls activeChatId = chat.id  on appear
//    ChatViewModel calls activeChatId = nil       on disappear
//    Backgrounding does NOT clear it — hence the applicationState test in isChatVisible.
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
    ///
    /// Suppression requires the chat to be open **and** the app to be on screen. `activeChatId`
    /// is cleared by ChatViewModel on disappear, which never happens when the user simply
    /// backgrounds the app with a chat open — so the flag stayed set for the whole background
    /// period and silently swallowed every banner for that conversation (observed 2026-07-31:
    /// 20+ minutes backgrounded, three messages, no notification, `unreadCount` stuck at 0).
    /// Same `applicationState` test `handleFloodAlert` below already applies.
    func handle(chatId: String, isMuted: Bool, senderName: String, preview: String) {
        guard !isMuted else { return }
        guard !Self.isChatVisible(chatId) else { return }

        LocalNotificationManager.shared.showNewMessageNotification(chatId: chatId)
    }

    /// True only when `chatId` is the open conversation AND the app is actually on screen.
    /// The single authority for "the user can already see this message".
    ///
    static func isChatVisible(_ chatId: String) -> Bool {
        isChatVisible(chatId, activeChatId: shared.activeChatId, appIsActive: appIsActive)
    }

    /// Pure decision, split from the live reads so the backgrounded branch is reachable from
    /// tests — `UIApplication.applicationState` is always `.active` under XCTest, and that is
    /// exactly the term whose absence caused the bug.
    nonisolated static func isChatVisible(_ chatId: String, activeChatId: String?, appIsActive: Bool) -> Bool {
        chatId == activeChatId && appIsActive
    }

    /// Live app-foreground state.
    static var appIsActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
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
                Log.error("InAppNotification: flood alert failed — \(error)", category: "Notifications")
            }
        }
    }
}
