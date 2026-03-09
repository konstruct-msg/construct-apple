//
//  SessionStore.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation

final class SessionStore {
    private var sessionIds: [String: String] = [:]
    private var suiteIds: [String: UInt16] = [:]
    private let queue = DispatchQueue(label: "com.construct.sessionStore", attributes: .concurrent)

    func hasSession(for userId: String) -> Bool {
        queue.sync { sessionIds[userId] != nil }
    }

    func getSessionId(for userId: String) -> String? {
        queue.sync { sessionIds[userId] }
    }

    func getSuiteId(for userId: String) -> UInt16? {
        queue.sync { suiteIds[userId] }
    }

    func setSession(userId: String, sessionId: String, suiteId: UInt16) {
        queue.async(flags: .barrier) {
            self.sessionIds[userId] = sessionId
            self.suiteIds[userId] = suiteId
        }
    }

    func removeSession(for userId: String) {
        queue.async(flags: .barrier) {
            self.sessionIds.removeValue(forKey: userId)
            self.suiteIds.removeValue(forKey: userId)
        }
    }

    func allUserIds() -> [String] {
        queue.sync { Array(sessionIds.keys) }
    }

    func restoreSessionIfNeeded(userId: String, core: ClassicCryptoCore?, keychain: KeychainManager = .shared, onLog: ((String) -> Void)? = nil) -> Bool {
        // Check without holding the lock during the potentially throwing Rust call
        let alreadyRestored = queue.sync { sessionIds[userId] != nil }
        guard !alreadyRestored else { return true }
        guard let core = core else { return false }
        guard let sessionJson = keychain.loadSessionJson(for: userId) else { return false }

        do {
            let sessionId = try core.importSessionJson(contactId: userId, sessionJson: sessionJson)
            queue.async(flags: .barrier) { self.sessionIds[userId] = sessionId }
            onLog?("✅ Restored session: \(userId)")
            return true
        } catch {
            onLog?("⚠️ Failed to restore session for \(userId): \(error)")
            return false
        }
    }

    func saveSessionToKeychain(userId: String, core: ClassicCryptoCore?, keychain: KeychainManager = .shared, onLog: ((String) -> Void)? = nil) {
        guard let core = core else { return }

        do {
            let sessionJson = try core.exportSessionJson(contactId: userId)
            let saved = keychain.saveSessionJson(sessionJson, for: userId)
            if saved {
                onLog?("💾 Session saved to Keychain: \(userId)")
            } else {
                onLog?("⚠️ Failed to save session to Keychain: \(userId)")
            }
        } catch {
            onLog?("❌ Session export failed: \(error)")
        }
    }
}
