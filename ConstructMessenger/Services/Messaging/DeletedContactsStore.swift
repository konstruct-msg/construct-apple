//
//  DeletedContactsStore.swift
//  Construct Messenger
//
//  Persistent store of user IDs whose chats were explicitly deleted by the local user.
//
//  Purpose:
//  When a chat is deleted, the server keeps re-delivering the contact's messages on every
//  reconnect (fetchMissedMessages), causing MessageRouter to recreate the User+Chat entities.
//  This store lets MessageRouter silently ACK and skip messages from deleted contacts so the
//  chat never reappears unless the user explicitly initiates a new conversation.
//
//  Storage: UserDefaults — lightweight, no Core Data migration needed.
//  Thread safety: protected by NSLock (called from @MainActor, but keeping it safe).
//

import Foundation

final class DeletedContactsStore {

    static let shared = DeletedContactsStore()
    private init() { load() }

    private let defaultsKey = "com.konstruct.deletedContacts.v1"
    private var deletedIds: Set<String> = []
    private let lock = NSLock()

    // MARK: - Public API

    /// Returns true if the user explicitly deleted their chat with `userId`.
    func isDeleted(_ userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deletedIds.contains(userId)
    }

    /// Mark a contact as deleted. Call when the user deletes a chat.
    func add(_ userId: String) {
        lock.lock()
        deletedIds.insert(userId)
        lock.unlock()
        persist()
    }

    /// Unmark a contact (e.g. if the local user initiates a new conversation with them).
    func remove(_ userId: String) {
        lock.lock()
        deletedIds.remove(userId)
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        deletedIds = Set(saved)
    }

    private func persist() {
        lock.lock()
        let snapshot = Array(deletedIds)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }
}
