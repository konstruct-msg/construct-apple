//
//  PersistentACKStore.swift
//  Construct Messenger
//
//  Persistent acknowledgment store for processed messages.
//
//  Prevents duplicate message processing across app restarts caused by server
//  re-delivering unacknowledged messages on reconnect.
//
//  Architecture:
//  - Hot path: in-memory Set<String> for O(1) lookup within a session
//  - Durable path: CoreData `ProcessedMessage` entity (survives restart)
//  - TTL: entries older than `retentionDays` are pruned on app launch

import Foundation
import CoreData

final class PersistentACKStore {

    static let shared = PersistentACKStore()

    /// Number of days to retain ACK entries. Matches server re-delivery window.
    static let retentionDays = 30

    /// In-memory cache for hot-path dedup within the current app session.
    private var cache: Set<String> = []
    private let cacheLock = NSLock()

    private init() {}

    // MARK: - Check

    /// Returns `true` if the message was already processed (in-memory or persisted).
    func isProcessed(_ messageId: String, in context: NSManagedObjectContext) -> Bool {
        cacheLock.lock()
        let cached = cache.contains(messageId)
        cacheLock.unlock()
        if cached { return true }

        var found = false
        context.performAndWait {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            found = (try? context.fetch(fetch))?.isEmpty == false
            if found {
                cacheLock.lock()
                cache.insert(messageId)
                cacheLock.unlock()
            }
        }
        return found
    }

    // MARK: - Mark

    /// Marks `messageId` as processed. Idempotent — safe to call multiple times.
    func markProcessed(_ messageId: String, senderId: String, in context: NSManagedObjectContext) {
        // Cache first so any concurrent in-flight check sees it immediately
        cacheLock.lock()
        cache.insert(messageId)
        cacheLock.unlock()

        // Persist on the context's own queue
        context.performAndWait {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            guard (try? context.fetch(fetch))?.isEmpty != false else { return }

            let record = ProcessedMessage(context: context)
            record.messageId = messageId
            record.senderId = senderId
            record.processedAt = Date()

            do {
                try context.save()
            } catch {
                Log.error("❌ PersistentACKStore: failed to save ACK for \(messageId.prefix(8))…: \(error)", category: "PersistentACK")
            }
        }
    }

    // MARK: - Cleanup

    /// Deletes ACK entries older than `retentionDays`. Call once per app launch.
    func pruneExpired(in context: NSManagedObjectContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date.distantPast
        let fetch = ProcessedMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "processedAt < %@", cutoff as NSDate)

        do {
            let expired = try context.fetch(fetch)
            if !expired.isEmpty {
                Log.info("🧹 PersistentACKStore: pruning \(expired.count) expired ACK(s)", category: "PersistentACK")
                expired.forEach { context.delete($0) }
                try context.save()
            }
        } catch {
            Log.error("❌ PersistentACKStore: prune failed: \(error)", category: "PersistentACK")
        }
    }
}
