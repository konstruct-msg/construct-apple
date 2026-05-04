// EngineAdapter.swift
// Construct Messenger
//
// Bridges construct-engine (UniFFI) to iOS platform services.
// Implements EngineCallback so the Rust engine can call back into Swift
// for Keychain, CoreData, notifications, and ViewModel updates.
//
// Usage:
//   let adapter = EngineAdapter.shared
//   try adapter.start()
//   adapter.dispatch(.openMessageStream(userId: myId, deviceId: myDeviceId))

import Foundation
import CoreData
import UIKit
import UserNotifications

// MARK: - Notification names posted by the adapter

extension Notification.Name {
    /// A new plaintext message arrived. userInfo: ["senderId": String, "conversationId": String,
    /// "plaintext": Data, "timestamp": Int64]
    static let engineMessageReceived  = Notification.Name("cc.konstruct.engine.messageReceived")
    /// A session with a contact was established or re-established.
    /// userInfo: ["contactId": String, "sessionId": String]
    static let engineSessionEstablished = Notification.Name("cc.konstruct.engine.sessionEstablished")
    /// A session error occurred. userInfo: ["contactId": String, "message": String]
    static let engineSessionError = Notification.Name("cc.konstruct.engine.sessionError")
    /// Outgoing message status changed. userInfo: ["localId": String, "status": UInt8]
    static let engineMessageStatusUpdated = Notification.Name("cc.konstruct.engine.messageStatusUpdated")
    /// Engine transport connection state changed. userInfo: ["connected": Bool]
    static let engineConnectionStateChanged = Notification.Name("cc.konstruct.engine.connectionStateChanged")
    /// Registration completed — engine has userId + deviceId.
    /// userInfo: ["userId": String, "deviceId": String]
    static let engineRegistrationComplete = Notification.Name("cc.konstruct.engine.registrationComplete")
    /// Auth token was refreshed. No userInfo — call KeychainManager if you need the token.
    static let engineAuthTokenUpdated = Notification.Name("cc.konstruct.engine.authTokenUpdated")
    /// Background fetch finished. userInfo: ["decryptedCount": UInt32, "hadErrors": Bool]
    static let engineBackgroundFetchComplete = Notification.Name("cc.konstruct.engine.backgroundFetchComplete")
}

// MARK: - EngineAdapter

/// Singleton bridge between construct-engine and iOS.
///
/// Thread model:
/// - `onAction` is called from an arbitrary thread by UniFFI.
///   All mutations to @Observable properties and CoreData happen on `@MainActor` via `Task { @MainActor in }`.
/// - `dispatch()` is safe to call from any thread.
@Observable
@MainActor
final class EngineAdapter {

    static let shared = EngineAdapter()

    // MARK: - Observable state (ViewModel-accessible)

    /// Current transport connection state (true = H3 live).
    private(set) var isConnected: Bool = false

    /// Last unrecoverable error from the engine.
    private(set) var lastError: String?

    // MARK: - Private

    private var engine: ConstructEngine?
    /// APNs background completion handler. Set by AppDelegate, called in BackgroundFetchComplete.
    var backgroundFetchCompletion: ((UIBackgroundFetchResult) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Build the engine from Keychain state and start it.
    /// Call this from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    func start() throws {
        guard engine == nil else { return }

        let km = KeychainManager.shared
        let config = EngineConfig(
            serverHost: resolvedServerHost(),
            serverPort: 443,
            myDeviceId: km.loadDeviceID() ?? "",
            myUserId:   km.loadUserID() ?? "",
            keysCfeData: km.loadPrivateKeysData() ?? Data(),
            authToken:  km.loadSessionToken(),
            verifyCerts: true,
            useMasque: false,
            masqueHost: nil,
            masquePort: nil,
            eventBuffer: 1024
        )

        let eng = try ConstructEngine(config: config, callback: self)
        try eng.start()
        self.engine = eng

        // Restore sessions and auth state into the engine via KeychainResult events.
        eng.dispatch(event: .platformReady)
    }

    /// Dispatch a UiEvent to the engine. No-op if engine is not yet started.
    func dispatch(_ event: UiEvent) {
        engine?.dispatch(event: event)
    }

    // MARK: - Helpers

    private func resolvedServerHost() -> String {
        // Strip scheme and port from the full URL stored in APIConstants.
        let full = APIConstants.activeServerURL    // e.g. "https://ams.konstruct.cc"
        return full
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://",  with: "")
            .components(separatedBy: ":").first ?? "ams.konstruct.cc"
    }
}

// MARK: - EngineCallback (UniFFI)

extension EngineAdapter: EngineCallback {

    /// Called by the Rust engine on an arbitrary thread.
    /// All UI/CoreData work is dispatched to the main actor.
    nonisolated func onAction(action: PlatformAction) {
        switch action {

        // ── Keychain ─────────────────────────────────────────────────────────
        case .saveKeychain(let key, let data):
            let ok = KeychainManager.shared.saveData(data, forKey: key)
            if !ok { Log.error("EngineAdapter: saveKeychain failed for key '\(key)'", category: "Engine") }

        case .loadKeychain(let key):
            let data = KeychainManager.shared.loadData(forKey: key)
            Task { @MainActor in
                self.dispatch(.keychainResult(key: key, data: data))
            }

        case .deleteKeychain(let key):
            KeychainManager.shared.deleteData(forKey: key)

        // ── Auth ─────────────────────────────────────────────────────────────
        case .setAuthToken(let userId, let accessToken, let refreshToken, _):
            KeychainManager.shared.saveSessionToken(accessToken)
            KeychainManager.shared.saveRefreshToken(refreshToken)
            KeychainManager.shared.saveUserID(userId)
            Task { @MainActor in
                NotificationCenter.default.post(name: .engineAuthTokenUpdated, object: nil)
            }

        case .clearAuth:
            KeychainManager.shared.deleteSessionToken()
            KeychainManager.shared.deleteRefreshToken()

        // ── Registration ─────────────────────────────────────────────────────
        case .registrationComplete(let userId, let deviceId):
            KeychainManager.shared.saveUserID(userId)
            KeychainManager.shared.saveDeviceID(deviceId)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineRegistrationComplete,
                    object: nil,
                    userInfo: ["userId": userId, "deviceId": deviceId]
                )
            }

        // ── Messages ─────────────────────────────────────────────────────────
        case .displayMessage(let messageId, let plaintext, let senderId, let conversationId, let timestamp):
            persistIncomingMessage(
                messageId: messageId,
                plaintext: plaintext,
                senderId: senderId,
                conversationId: conversationId,
                timestamp: timestamp
            )
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageReceived,
                    object: nil,
                    userInfo: [
                        "messageId":      messageId,
                        "senderId":       senderId,
                        "conversationId": conversationId,
                        "plaintext":      plaintext,
                        "timestamp":      timestamp,
                    ]
                )
            }

        case .updateMessageStatus(let localId, let status):
            persistUpdateMessageStatus(localId: localId, status: status)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageStatusUpdated,
                    object: nil,
                    userInfo: ["localId": localId, "status": status]
                )
            }

        case .saveMessage(_, let senderId, let conversationId, let timestamp):
            Log.debug("EngineAdapter: saveMessage sender=\(senderId) conv=\(conversationId) ts=\(timestamp)", category: "Engine")

        case .deliveryReceipt(let messageId, let conversationId, _):
            persistUpdateMessageStatus(localId: messageId, status: 2) // 2 = delivered
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageStatusUpdated,
                    object: nil,
                    userInfo: ["localId": messageId, "conversationId": conversationId, "status": UInt8(2)]
                )
            }

        // ── Sessions ─────────────────────────────────────────────────────────
        case .sessionEstablished(let contactId, let sessionId):
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineSessionEstablished,
                    object: nil,
                    userInfo: ["contactId": contactId, "sessionId": sessionId]
                )
            }

        case .sessionError(let contactId, let message):
            Log.error("EngineAdapter: sessionError contact=\(contactId) \(message)", category: "Engine")
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineSessionError,
                    object: nil,
                    userInfo: ["contactId": contactId, "message": message]
                )
            }

        // ── Key management (informational) ───────────────────────────────────
        case .preKeyBundleReady(let userId, _):
            Log.debug("EngineAdapter: preKeyBundleReady userId=\(userId)", category: "Engine")

        case .otpksUploaded(let uploaded, let serverCount):
            Log.info("EngineAdapter: otpks uploaded=\(uploaded) serverCount=\(serverCount)", category: "Engine")

        case .preKeyCountUpdated(let count, let min):
            Log.debug("EngineAdapter: preKeyCount=\(count) min=\(min)", category: "Engine")

        case .spkRotated(let keyId):
            Log.info("EngineAdapter: SPK rotated keyId=\(keyId)", category: "Engine")

        // ── Stream ───────────────────────────────────────────────────────────
        case .streamReady(let cursor):
            Log.info("EngineAdapter: stream ready cursor=\(cursor ?? "nil")", category: "Engine")
            Task { @MainActor in self.isConnected = true }

        case .streamError(let message):
            Log.error("EngineAdapter: streamError \(message)", category: "Engine")
            Task { @MainActor in self.isConnected = false }

        // ── Calls ────────────────────────────────────────────────────────────
        case .incomingCall(let callId, let callerId, let signalBytes):
            Log.info("EngineAdapter: incomingCall callId=\(callId) caller=\(callerId) signal=\(signalBytes.count)b", category: "Engine")
            // TODO: hand off to CallKit via existing CallsService

        case .callSignalReceived(let callId, let signalBytes):
            Log.debug("EngineAdapter: callSignal callId=\(callId) \(signalBytes.count)b", category: "Engine")

        // ── Network / Debug ──────────────────────────────────────────────────
        case .connectionStateChanged(let connected):
            Task { @MainActor in
                self.isConnected = connected
                NotificationCenter.default.post(
                    name: .engineConnectionStateChanged,
                    object: nil,
                    userInfo: ["connected": connected]
                )
            }

        case .networkError(let message):
            Log.error("EngineAdapter: networkError \(message)", category: "Engine")
            Task { @MainActor in
                self.lastError = message
                self.isConnected = false
            }

        case .log(let level, let message):
            switch level {
            case "ERROR": Log.error("[engine] \(message)", category: "Engine")
            case "WARN":  Log.error("[engine] \(message)",  category: "Engine")
            case "INFO":  Log.info("[engine] \(message)",  category: "Engine")
            default:      Log.debug("[engine] \(message)", category: "Engine")
            }

        // ── Background push ──────────────────────────────────────────────────
        case .showNotification(let messageId, let senderId, let conversationId, let preview, _):
            postLocalNotification(
                messageId: messageId,
                senderId: senderId,
                conversationId: conversationId,
                preview: preview
            )

        case .backgroundFetchComplete(let count, let hadErrors):
            Log.info("EngineAdapter: backgroundFetchComplete decrypted=\(count) errors=\(hadErrors)", category: "Engine")
            Task { @MainActor in
                let result: UIBackgroundFetchResult = count > 0 ? .newData : (hadErrors ? .failed : .noData)
                self.backgroundFetchCompletion?(result)
                self.backgroundFetchCompletion = nil
                NotificationCenter.default.post(
                    name: .engineBackgroundFetchComplete,
                    object: nil,
                    userInfo: ["decryptedCount": count, "hadErrors": hadErrors]
                )
            }
        }
    }

    // MARK: - CoreData persistence (incoming messages)

    /// Persists a decrypted incoming message to CoreData on a private background context.
    /// Merges changes into the viewContext so FetchRequest / @Observable views update automatically.
    private nonisolated func persistIncomingMessage(
        messageId: String,
        plaintext: Data,
        senderId: String,
        conversationId: String,
        timestamp: Int64
    ) {
        guard let plaintext = String(data: plaintext, encoding: .utf8), !plaintext.isEmpty else {
            Log.debug("EngineAdapter: displayMessage plaintext empty or non-UTF8 — skipping persist", category: "Engine")
            return
        }
        let container = PersistenceController.shared.container
        let bgCtx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        bgCtx.persistentStoreCoordinator = container.viewContext.persistentStoreCoordinator

        bgCtx.perform {
            // Deduplication: skip if already persisted.
            let dedupReq = Message.fetchRequest()
            dedupReq.predicate = NSPredicate(format: "id ==[c] %@", messageId)
            dedupReq.fetchLimit = 1
            if (try? bgCtx.fetch(dedupReq).first) != nil {
                Log.debug("EngineAdapter: duplicate message \(messageId.prefix(8))… — skipping", category: "Engine")
                return
            }

            // Find or create the Chat entity (id = conversationId = other user's userId for DMs).
            let chat = self.findOrCreateChat(conversationId: conversationId, in: bgCtx)

            let message = Message(context: bgCtx)
            message.id = messageId.lowercased()
            message.fromUserId = senderId
            message.toUserId = KeychainManager.shared.loadUserID() ?? ""
            message.contentType = .regular
            message.timestamp = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
            message.isSentByMe = false
            message.deliveryStatus = .delivered
            message.retryCount = 0
            message.chat = chat

            message.applyStoredEncryption(plaintext: plaintext, contactId: conversationId)

            chat.unreadCount += 1
            let msgTime = message.timestamp
            if chat.lastMessageTime == nil || msgTime > (chat.lastMessageTime ?? .distantPast) {
                chat.lastMessageText = Chat.formatPreviewText(plaintext)
                chat.lastMessageTime = msgTime
            }

            do {
                try bgCtx.save()
                // Merge into viewContext on main thread so FRC/Observable updates fire.
                DispatchQueue.main.async {
                    container.viewContext.mergeChanges(
                        fromContextDidSave: Notification(
                            name: NSManagedObjectContext.didSaveObjectsNotification,
                            object: bgCtx
                        )
                    )
                }
                Log.debug("EngineAdapter: persisted message \(messageId.prefix(8))…", category: "Engine")
            } catch {
                Log.error("EngineAdapter: CoreData save failed: \(error)", category: "Engine")
            }
        }
    }

    /// Finds the Chat entity for the given conversationId, or creates it if not found.
    /// Must be called on the context's queue.
    private nonisolated func findOrCreateChat(
        conversationId: String,
        in context: NSManagedObjectContext
    ) -> Chat {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id ==[c] %@", conversationId)
        req.fetchLimit = 1
        if let existing = try? context.fetch(req).first {
            return existing
        }
        let chat = Chat(context: context)
        chat.id = conversationId
        chat.unreadCount = 0
        chat.isPinned = false
        chat.isMuted = false
        return chat
    }

    /// Updates delivery status of an existing message in CoreData.
    private nonisolated func persistUpdateMessageStatus(localId: String, status: UInt8) {
        let deliveryStatus: DeliveryStatus = {
            switch status {
            case 0: return .sending
            case 1: return .sent
            case 2: return .delivered
            case 3: return .queued
            case 4: return .failed
            default: return .sent
            }
        }()

        let container = PersistenceController.shared.container
        let bgCtx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        bgCtx.persistentStoreCoordinator = container.viewContext.persistentStoreCoordinator

        bgCtx.perform {
            let req = Message.fetchRequest()
            req.predicate = NSPredicate(format: "id ==[c] %@", localId)
            req.fetchLimit = 1
            guard let message = try? bgCtx.fetch(req).first else {
                Log.debug("EngineAdapter: updateMessageStatus — message \(localId.prefix(8))… not found", category: "Engine")
                return
            }
            message.deliveryStatus = deliveryStatus
            do {
                try bgCtx.save()
                DispatchQueue.main.async {
                    container.viewContext.mergeChanges(
                        fromContextDidSave: Notification(
                            name: NSManagedObjectContext.didSaveObjectsNotification,
                            object: bgCtx
                        )
                    )
                    // Keep MessageQueueManager watchdog in sync: clear the pending timer
                    // when the engine confirms the send so the watchdog doesn't
                    // incorrectly re-queue a message that was already delivered.
                    switch deliveryStatus {
                    case .sent, .delivered:
                        MessageQueueManager.shared.markMessageAsSent(localId)
                    case .failed, .queued:
                        MessageQueueManager.shared.markMessageAsFailed(localId)
                    case .sending:
                        break
                    }
                }
            } catch {
                Log.error("EngineAdapter: status update CoreData save failed: \(error)", category: "Engine")
            }
        }
    }

    // MARK: - Local notification helper (background push)

    private nonisolated func postLocalNotification(
        messageId: String,
        senderId: String,
        conversationId: String,
        preview: Data?
    ) {
        let content = UNMutableNotificationContent()
        // Privacy-first: never expose sender name or actual preview in the push notification.
        // Show only a generic indicator matching E2EE privacy model.
        content.title = NSLocalizedString("notification.new_message.title", comment: "New message notification title")
        content.body  = NSLocalizedString("notification.new_message.body",  comment: "New message notification body")
        content.sound = .default
        // Thread identifier collapses multiple notifications per conversation.
        content.threadIdentifier = conversationId
        // Category identifier allows the system to group and handle actions.
        content.categoryIdentifier = "CONSTRUCT_MESSAGE"
        // userInfo for deep-link routing when user taps the notification.
        content.userInfo = [
            "messageId":      messageId,
            "senderId":       senderId,
            "conversationId": conversationId,
        ]

        let request = UNNotificationRequest(
            identifier: messageId,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("EngineAdapter: notification add failed: \(error)", category: "Engine") }
        }
    }
}
