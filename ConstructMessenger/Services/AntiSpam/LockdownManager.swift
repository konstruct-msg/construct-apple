//
//  LockdownManager.swift
//  Construct Messenger
//
//  "Lockdown mode" — when active, only existing contacts can reach the user
//  with notifications. New senders (added after lockdown was enabled) have their
//  notifications silently suppressed until the user manually lifts lockdown.
//
//  This is a receiver-side protection that cannot be bypassed by a custom API
//  client — messages still arrive and are decrypted, but the UI is shielded.
//

import Foundation
import Combine

// MARK: - LockdownManager

/// Observable singleton for Lockdown mode.
///
/// When lockdown is enabled:
/// 1. A snapshot of all approved sender IDs is taken from Core Data.
/// 2. Any incoming message from a sender NOT in the snapshot is silently
///    suppressed (saved to Core Data but no notification shown).
/// 3. The user can review suppressed senders in Settings and approve individually.
@Observable
final class LockdownManager {

    static let shared = LockdownManager()

    // MARK: - State

    private(set) var isActive: Bool = false
    private(set) var activatedAt: Date? = nil

    // MARK: - Approved senders snapshot

    /// Set of user IDs approved before lockdown was activated.
    /// Empty when lockdown is inactive.
    private(set) var approvedSenders: Set<String> = []

    // MARK: - Keys

    private enum Key {
        static let isActive       = "com.construct.lockdown.isActive"
        static let activatedAt    = "com.construct.lockdown.activatedAt"
        static let approvedSenders = "com.construct.lockdown.approvedSenders"
    }

    private init() {
        let d = UserDefaults.standard
        isActive    = d.bool(forKey: Key.isActive)
        activatedAt = d.object(forKey: Key.activatedAt) as? Date
        let stored  = d.stringArray(forKey: Key.approvedSenders) ?? []
        approvedSenders = Set(stored)
    }

    // MARK: - Enable / disable

    /// Activate lockdown.
    ///
    /// - Parameter approvedIds: IDs of all contacts that should still get through
    ///   (typically all `Chat.otherUser.id` values currently in Core Data).
    func enable(approvedIds: Set<String>) {
        isActive = true
        activatedAt = Date()
        approvedSenders = approvedIds
        persist()
        Log.info("🔒 Lockdown ENABLED — \(approvedIds.count) approved senders", category: "LockdownManager")
    }

    func disable() {
        isActive = false
        activatedAt = nil
        approvedSenders = []
        persist()
        Log.info("🔓 Lockdown DISABLED", category: "LockdownManager")
    }

    // MARK: - Per-message check

    /// Returns `true` if the incoming message from `senderId` should be suppressed.
    func shouldSuppress(senderId: String) -> Bool {
        guard isActive else { return false }
        return !approvedSenders.contains(senderId)
    }

    /// Allow a specific sender through without disabling lockdown entirely.
    func approveSender(_ id: String) {
        approvedSenders.insert(id)
        persist()
        Log.info("🔓 Lockdown: manually approved sender \(id.prefix(8))…", category: "LockdownManager")
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(isActive,               forKey: Key.isActive)
        d.set(activatedAt,            forKey: Key.activatedAt)
        d.set(Array(approvedSenders), forKey: Key.approvedSenders)
    }
}
