//
//  SessionHealingService.swift
//  Construct Messenger
//
//  Session healing — recover a broken crypto session WITHOUT sending END_SESSION.
//
//  When is healing applicable?
//  ─────────────────────────────────────────────────────────────────────────────
//  When an incoming message fails to decrypt AND `messageNumber == 0`, it means
//  the remote peer RESTARTED their session (re-keyed) — common after reinstall,
//  manual key rotation, or a prekey mismatch on the initial X3DH handshake.
//
//  In this case, the failed message IS the new X3DH init.  We can:
//    1. Archive the current (broken) local session.
//    2. Treat the failed message exactly like a first message.
//    3. Fetch a fresh bundle and call `initReceivingSession` with the message.
//
//  When healing is NOT applicable (messageNumber > 0):
//  ─────────────────────────────────────────────────────────────────────────────
//  The Double Ratchet is mid-chain.  The ratchet state has diverged and we
//  cannot reconstruct the missing chain steps without the sender's session
//  state.  END_SESSION is the only correct recovery.
//
//  Persistent Healing Queue
//  ─────────────────────────────────────────────────────────────────────────────
//  While healing is in progress the failed `messageNumber==0` message is stored
//  in CoreData (`HealingMessage` entity) so that an app restart during the
//  healing attempt doesn't permanently lose the message.
//  TTL: entries older than 24 hours are pruned (server re-delivers anyway).
//
//  Migration status: Phase M2 complete — attempt tracking and canHeal delegated to
//  Rust RustHealingQueue. CoreData persistence remains for message recovery across
//  restarts until OrchestratorCore PlatformBridge takes over (Phase M4).

import Foundation
import CoreData

final class SessionHealingService {

    static let shared = SessionHealingService()

    /// Max number of heal attempts before giving up and sending END_SESSION.
    private let maxHealAttempts: Int32 = 3

    /// How long to retain a HealingMessage before considering it stale.
    private let healingTTLHours = 24

    /// Rust-backed attempt tracker. Keyed by senderId (one healing slot per contact).
    private let rustQueue = RustHealingQueue()

    private static let queueStateKey = "construct.healing_queue_state"

    private init() {}

    // MARK: - Persistence

    /// Serialise the Rust healing queue to Keychain. Call after every mutation.
    private func saveQueueState() {
        let blob = rustQueue.exportState()
        guard !blob.isEmpty else { return }
        _ = KeychainManager.shared.saveRawData(Data(blob), forKey: Self.queueStateKey)
    }

    /// Restore the Rust healing queue from Keychain. Call on app startup.
    func restoreQueueState() {
        guard let data = KeychainManager.shared.loadRawData(forKey: Self.queueStateKey) else { return }
        rustQueue.importState(data: [UInt8](data))
        Log.info("SessionHealingService: restored queue state (\(data.count) bytes)", category: "SessionHealing")
    }

    // MARK: - Canary

    /// Returns `true` when the message CAN be healed without END_SESSION.
    func canHeal(_ message: ChatMessage) -> Bool {
        return rustQueue.canHeal(msgNumber: UInt32(message.messageNumber))
    }

    // MARK: - Enqueue

    /// Persists `message` to the healing queue so it survives an app restart.
    func enqueue(_ message: ChatMessage, in context: NSManagedObjectContext) {
        guard let data = try? JSONEncoder().encode(message),
              let messageJson = String(data: data, encoding: .utf8) else {
            Log.error("SessionHealingService: failed to encode message \(message.id.prefix(8))…", category: "SessionHealing")
            return
        }

        rustQueue.enqueue(contactId: message.from, messageJson: messageJson)
        saveQueueState()

        // CoreData persistence (survives app restart until PlatformBridge migration)
        let fetch = HealingMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "messageId == %@", message.id)
        fetch.fetchLimit = 1
        guard (try? context.fetch(fetch))?.isEmpty != false else { return }

        let record = HealingMessage(context: context)
        record.messageId = message.id
        record.senderId = message.from
        record.receivedAt = Date()
        record.messageData = data
        record.healAttempts = 0
        record.lastAttemptAt = nil

        do {
            try context.save()
            Log.info("SessionHealingService: enqueued message \(message.id.prefix(8))… for healing", category: "SessionHealing")
        } catch {
            Log.error("SessionHealingService: failed to persist healing message: \(error)", category: "SessionHealing")
        }
    }

    // MARK: - Attempt Tracking

    /// Returns the persisted healing message for `messageId`, or nil.
    func healingRecord(for messageId: String, in context: NSManagedObjectContext) -> HealingMessage? {
        let fetch = HealingMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        fetch.fetchLimit = 1
        return (try? context.fetch(fetch))?.first
    }

    /// Returns all pending messages for `senderId` sorted oldest-first.
    func pendingMessages(from senderId: String, in context: NSManagedObjectContext) -> [ChatMessage] {
        let fetch = HealingMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "senderId == %@", senderId)
        fetch.sortDescriptors = [NSSortDescriptor(key: "receivedAt", ascending: true)]

        guard let records = try? context.fetch(fetch) else { return [] }
        return records.compactMap { try? JSONDecoder().decode(ChatMessage.self, from: $0.messageData) }
    }

    /// Increments the attempt counter. Returns `false` when max retries are exhausted.
    /// Rust tracks attempts per-contact; CoreData is updated for persistence across restarts.
    @discardableResult
    func recordAttempt(for messageId: String, in context: NSManagedObjectContext) -> Bool {
        var shouldContinue = false
        context.performAndWait {
            guard let record = healingRecord(for: messageId, in: context) else { return }

            let result = rustQueue.recordAttempt(contactId: record.senderId)
            shouldContinue = result.decision == "retry_allowed"
            saveQueueState()

            record.healAttempts += 1
            record.lastAttemptAt = Date()
            do { try context.save() } catch {}

            if !shouldContinue {
                Log.info("SessionHealingService: max attempts reached for \(messageId.prefix(8))…", category: "SessionHealing")
            }
        }
        return shouldContinue
    }

    // MARK: - Remove

    /// Removes the healing record when the session is successfully healed.
    func removeRecord(for messageId: String, in context: NSManagedObjectContext) {
        if let record = healingRecord(for: messageId, in: context) {
            _ = rustQueue.removeRecord(contactId: record.senderId)
            saveQueueState()
            context.delete(record)
        }
        context.saveAndLog()
    }

    /// Removes ALL healing records for `senderId`.
    func clearQueue(for senderId: String, in context: NSManagedObjectContext) {
        _ = rustQueue.removeRecord(contactId: senderId)
        saveQueueState()

        let fetch = HealingMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "senderId == %@", senderId)
        guard let records = try? context.fetch(fetch) else { return }
        if !records.isEmpty {
            Log.info("SessionHealingService: clearing \(records.count) healing record(s) for \(senderId.prefix(8))…", category: "SessionHealing")
            records.forEach { context.delete($0) }
            context.saveAndLog()
        }
    }

    // MARK: - Cleanup

    /// Prunes stale records older than `healingTTLHours`. Call on app launch.
    func pruneExpired(in context: NSManagedObjectContext) {
        rustQueue.pruneExpired()

        let cutoff = Calendar.current.date(byAdding: .hour, value: -healingTTLHours, to: Date()) ?? Date.distantPast
        let fetch = HealingMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "receivedAt < %@", cutoff as NSDate)
        guard let stale = try? context.fetch(fetch), !stale.isEmpty else { return }
        Log.info("SessionHealingService: pruning \(stale.count) stale healing record(s)", category: "SessionHealing")
        stale.forEach { context.delete($0) }
        context.saveAndLog()
    }
}
