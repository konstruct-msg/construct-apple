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
        case .displayMessage(let plaintext, let senderId, let conversationId, let timestamp):
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageReceived,
                    object: nil,
                    userInfo: [
                        "senderId":       senderId,
                        "conversationId": conversationId,
                        "plaintext":      plaintext,
                        "timestamp":      timestamp,
                    ]
                )
            }

        case .updateMessageStatus(let localId, let status):
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageStatusUpdated,
                    object: nil,
                    userInfo: ["localId": localId, "status": status]
                )
            }

        case .saveMessage(_, let senderId, let conversationId, let timestamp):
            // saveMessage is fired for *outgoing* messages the engine persisted.
            // The CoreData write is handled by the ViewModel's send path — here
            // we only need to surface it if the ViewModel missed it (e.g. app restart).
            Log.debug("EngineAdapter: saveMessage sender=\(senderId) conv=\(conversationId) ts=\(timestamp)", category: "Engine")

        case .deliveryReceipt(let messageId, let conversationId, _):
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .engineMessageStatusUpdated,
                    object: nil,
                    userInfo: ["localId": messageId, "conversationId": conversationId, "status": UInt8(3)]
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
