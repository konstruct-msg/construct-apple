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
//  - Hot path: Rust RustAckStore (thread-safe in-memory HashMap, replaces Swift Set + NSLock)
//  - Durable path: CoreData `ProcessedMessage` entity (survives restart)
//  - TTL: entries older than `retentionDays` are pruned on app launch
//
//  Migration status: Phase M1 complete — in-memory cache fully delegated to Rust.
//  Next: replace CoreData path with PlatformBridge calls via OrchestratorCore (Phase M4).

import Foundation
import CoreData

final class PersistentACKStore {

    static let shared = PersistentACKStore()

    /// Number of days to retain ACK entries. Matches server re-delivery window.
    static let retentionDays = 30

    /// Rust-backed in-memory dedup cache. Replaces `cache: Set<String>` + `NSLock`.
    /// Thread-safety is guaranteed by the Mutex inside RustAckStore.
    private let rustAck = RustAckStore()

    private init() {}

    // MARK: - Check

    /// Returns `true` if the message was already processed (in-memory or persisted).
    func isProcessed(_ messageId: String, in context: NSManagedObjectContext) -> Bool {
        switch rustAck.isProcessed(messageId: messageId) {
        case .inCache:
            return true
        case .needDbCheck, .notProcessed:
            var found = false
            context.performAndWait {
                let fetch = ProcessedMessage.fetchRequest()
                fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
                fetch.fetchLimit = 1
                found = (try? context.fetch(fetch))?.isEmpty == false
                if found {
                    _ = rustAck.markProcessed(messageId: messageId)
                }
            }
            return found
        }
    }

    /// Async variant for Rust orchestrator `CheckAckInDb` callbacks.
    /// Queries Core Data on a background context without requiring the caller to supply one.
    func isProcessed(messageId: String) async -> Bool {
        let context = PersistenceController.shared.container.newBackgroundContext()
        return await context.perform {
            self.isProcessed(messageId, in: context)
        }
    }

    // MARK: - Mark

    /// Immediately marks `messageId` as processed **in the in-memory Rust cache only** (no IO).
    ///
    /// Call this on the same thread as `decryptMessage` to close the race window with the
    /// live gRPC stream.  The stream's `isProcessed` check consults the in-memory cache first
    /// (`.inCache` → true), so this single call is sufficient to prevent double-decryption.
    ///
    /// Always follow up with `markProcessed(_:senderId:in:)` on the background thread to
    /// persist the ACK to Core Data across app restarts.
    func preemptACK(_ messageId: String) {
        _ = rustAck.markProcessed(messageId: messageId)
    }

    /// Marks `messageId` as processed. Idempotent — safe to call multiple times.
    func markProcessed(_ messageId: String, senderId: String, in context: NSManagedObjectContext) {
        _ = rustAck.markProcessed(messageId: messageId)

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
        _ = rustAck.pruneExpired()

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
