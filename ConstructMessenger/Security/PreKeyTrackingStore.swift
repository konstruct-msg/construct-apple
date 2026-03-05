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

    init(storageKey: String = "tracked_prekey_ids") {
        self.storageKey = storageKey
        load()
    }

    func track(preKeyId: String, for userId: String) -> PreKeyTrackingResult {
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
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            tracked = decoded
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(tracked) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
