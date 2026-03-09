//
//  PreKeyTrackingStore.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation

enum PreKeyTrackingResult {
    case firstSeen
    case unchanged
    case changed(previous: String)
}

final class PreKeyTrackingStore {
    private let storageKey: String
    private var tracked: [String: String] = [:]
    private let lock = NSLock()

    init(storageKey: String = "tracked_prekey_ids") {
        self.storageKey = storageKey
        load()
    }

    func track(preKeyId: String, for userId: String) -> PreKeyTrackingResult {
        lock.lock()
        defer { lock.unlock() }
        let previous = tracked[userId]

        if previous == nil {
            tracked[userId] = preKeyId
            save()
            return .firstSeen
        }

        if previous != preKeyId {
            tracked[userId] = preKeyId
            save()
            return .changed(previous: previous ?? "")
        }

        return .unchanged
    }

    private func load() {
        // Primary: Keychain (encrypted social graph)
        if let data = KeychainManager.shared.loadData(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            tracked = decoded
            return
        }
        // Migration: if Keychain empty, check UserDefaults, then migrate and remove
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            tracked = decoded
            save()  // writes to Keychain
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(tracked) {
            _ = KeychainManager.shared.saveData(encoded, forKey: storageKey)
        }
    }
}
