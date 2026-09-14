//
//  DeletedContactsStore.swift
//  Construct Messenger
//
//  A short-lived shield against the server replaying a pruned contact straight back into a fresh
//  row. Not a block.
//
//  # What it is for
//
//  The server replays a conversation's backlog on every reconnect (`since_cursor` is not honoured
//  — see `backend/MESSAGING_INITIAL_POLL_IGNORES_SINCE_CURSOR.md`). Without this store,
//  `MessageRouter` re-created the User and Chat rows from that replay and the contact came back
//  after every single deletion — reported on device 2026-08-19.
//
//  # What it is not
//
//  It is not a block, and the entries expire because a store that never forgets *is* one. Refusing
//  someone is the block button's job and the server enforces it before delivery
//  (`is_blocked_by`, messaging-service). A client-side refusal is strictly weaker: the message is
//  still delivered, still costs battery and a decrypt attempt, and only then gets dropped — with
//  no signal to either side. This one grew into that role by accident, and on 2026-09-04 the
//  result was a peer sending five messages into a conversation that had silently stopped existing,
//  recoverable only by re-scanning a QR code.
//
//  # Why a TTL and not a classifier
//
//  Both. The classifier is the real door: `MessageRouter` resurrects a pruned contact only on a
//  **handshake**, and a replayed backlog is mid-ratchet traffic. The TTL bounds the one case the
//  classifier cannot judge — a handshake that was already in the backlog when the prune happened,
//  and which the replay can therefore still deliver. That window is the server's message
//  retention, not forever.
//
//  Storage: UserDefaults — lightweight, no Core Data migration needed.
//  Thread safety: protected by NSLock (called from @MainActor, but keeping it safe).
//

import Foundation

final class DeletedContactsStore {

    static let shared = DeletedContactsStore()
    private init() { load() }

    /// How long a prune keeps shielding. Matches the server's message retention: past it, no
    /// replay can still be carrying a handshake from before the prune, so the entry protects
    /// nothing and only withholds a contact who may have written since.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// Named `construct.*`, not `com.konstruct.*`, and that is not cosmetic: `AccountWipeKeysTests`
    /// scans the sources for `"construct.…"` literals and fails on any that no wipe list claims.
    /// The old name sat outside that scan, so a store of contact ids survived an account wipe and
    /// a new identity on the device inherited the previous one's pruned contacts.
    private let defaultsKey = "construct.deletedContacts.v2"
    /// The pre-TTL names, read once at load: a bare array of ids, under the unscanned key.
    private let legacyDefaultsKey = "com.konstruct.deletedContacts.v1"
    /// id → when it was pruned.
    private var deletedAt: [String: Date] = [:]
    private let lock = NSLock()

    // MARK: - Public API

    /// Whether `userId` was pruned recently enough to still be shielded.
    ///
    /// Expiry is decided here rather than by a sweep: a sweep that never runs leaves a store that
    /// never forgets, which is the state this type is being moved away from.
    func isDeleted(_ userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = deletedAt[userId] else { return false }
        return Self.isShielded(prunedAt: at, now: Date())
    }

    /// Whether a prune at `prunedAt` still shields, as of `now`.
    ///
    /// A named function rather than a comparison inside `isDeleted`, because the thing that must
    /// not regress is a **boundary**, and a boundary needs somewhere a test can state it without
    /// waiting a week or re-implementing the comparison — a test that re-implements it passes
    /// whatever the store does.
    nonisolated static func isShielded(prunedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(prunedAt) < retention
    }

    /// Mark a contact as pruned. Call when the user deletes the contact.
    func add(_ userId: String) {
        lock.lock()
        deletedAt[userId] = Date()
        lock.unlock()
        persist()
    }

    /// Unmark a contact — the user started a new conversation with them, or their handshake
    /// arrived and `MessageRouter` decided to let them back.
    func remove(_ userId: String) {
        lock.lock()
        deletedAt.removeValue(forKey: userId)
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        lock.lock()
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] {
            deletedAt = stored.mapValues { Date(timeIntervalSince1970: $0) }
        } else if let legacy = UserDefaults.standard.stringArray(forKey: legacyDefaultsKey), !legacy.isEmpty {
            // Migrated as pruned **now**, not as already expired: an upgrade must not hand every
            // previously-deleted contact a fresh path back on the next reconnect's replay, which
            // is the exact defect this store was written to stop.
            let now = Date()
            deletedAt = Dictionary(uniqueKeysWithValues: legacy.map { ($0, now) })
        }
        // Drop what has aged out, so an install that sits unopened does not carry a decade of ids.
        let cutoff = Date().addingTimeInterval(-Self.retention)
        deletedAt = deletedAt.filter { $0.value > cutoff }
        lock.unlock()
        persist()
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private func persist() {
        lock.lock()
        let snapshot = deletedAt.mapValues { $0.timeIntervalSince1970 }
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }
}
