//
//  SessionArchiveManager.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation

final class SessionArchiveManager {
    private let keychain: KeychainManager
    private let maxArchivedSessions: Int
    private let retentionDays: Int

    private var archives: [String: [SessionArchive]] = [:]

    init(
        keychain: KeychainManager = .shared,
        maxArchivedSessions: Int = 3,
        retentionDays: Int = 7
    ) {
        self.keychain = keychain
        self.maxArchivedSessions = maxArchivedSessions
        self.retentionDays = retentionDays
    }

    func loadArchives(for userId: String) -> [SessionArchive]? {
        if let cached = archives[userId] {
            return cached
        }
        guard let loaded = loadFromKeychain(for: userId) else {
            return nil
        }
        archives[userId] = loaded
        return loaded
    }

    func storeArchive(_ archive: SessionArchive, for userId: String) {
        var list = archives[userId] ?? []
        list.append(archive)
        if list.count > maxArchivedSessions {
            list = Array(list.suffix(maxArchivedSessions))
        }
        archives[userId] = list
        saveToKeychain(list, for: userId)
    }

    func restoreArchiveToCurrent(for userId: String, index: Int) {
        guard var list = archives[userId], list.indices.contains(index) else {
            return
        }
        list.remove(at: index)
        archives[userId] = list
        saveToKeychain(list, for: userId)
    }

    func clearArchives(for userId: String) {
        archives.removeValue(forKey: userId)
        let key = keychainKey(for: userId)
        keychain.deleteData(forKey: key)
    }

    func cleanupExpiredArchives() -> Int {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        var totalRemoved = 0

        for userId in archives.keys {
            guard var list = archives[userId] else { continue }
            let before = list.count
            list.removeAll { $0.archivedAt < cutoffDate }
            let removed = before - list.count
            if removed > 0 {
                archives[userId] = list.isEmpty ? nil : list
                saveToKeychain(list, for: userId)
                totalRemoved += removed
            }
        }

        return totalRemoved
    }

    private func keychainKey(for userId: String) -> String {
        "session_archives_\(userId)"
    }

    private func saveToKeychain(_ list: [SessionArchive], for userId: String) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(list)
            _ = keychain.saveData(data, forKey: keychainKey(for: userId))
        } catch {
            // Intentionally swallow errors here; caller handles logging.
        }
    }

    private func loadFromKeychain(for userId: String) -> [SessionArchive]? {
        guard let data = keychain.loadData(forKey: keychainKey(for: userId)) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SessionArchive].self, from: data)
        } catch {
            return nil
        }
    }
}
