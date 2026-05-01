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
                    rustAck.markProcessed(messageId: messageId)
                }
            }
            return found
        }
    }

    /// Async variant for Rust orchestrator `CheckAckInDb` callbacks.
    /// Queries Core Data on a background context without requiring the caller to supply one.
    func isProcessed(messageId: String) async -> Bool {
        let context = PersistenceController.shared.container.newBackgroundContext()
        let rustAckCopy = rustAck
        return await context.perform { [rustAck = rustAckCopy] in
            switch rustAck.isProcessed(messageId: messageId) {
            case .inCache:
                return true
            case .needDbCheck, .notProcessed:
                let fetch = ProcessedMessage.fetchRequest()
                fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
                fetch.fetchLimit = 1
                let found = (try? context.fetch(fetch))?.isEmpty == false
                if found {
                    rustAck.markProcessed(messageId: messageId)
                }
                return found
            }
        }
    }

    /// Query ONLY Core Data — bypass the in-memory ACK cache.
    ///
    /// Use this exclusively in the `CheckAckInDb` handler to avoid false-positive duplicates
    /// caused by `preemptACK` being called before the Rust orchestrator processes the message.
    /// `preemptACK` marks the message in the Swift-side RustAckStore to block BackgroundFetch,
    /// but the `CheckAckInDb` question is "was this processed in a *prior* session?" — the
    /// preempt mark must NOT answer that question with `true`.
    func isProcessedInCoreData(_ messageId: String, in context: NSManagedObjectContext) -> Bool {
        var found = false
        context.performAndWait {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            found = (try? context.fetch(fetch))?.isEmpty == false
            if found {
                rustAck.markProcessed(messageId: messageId)
            }
        }
        return found
    }

    /// Async Core-Data-only variant for the `CheckAckInDb` async callback path.
    /// Same rationale as `isProcessedInCoreData(_:in:)` — bypasses the preempt cache.
    func isProcessedInCoreData(messageId: String) async -> Bool {
        let context = PersistenceController.shared.container.newBackgroundContext()
        let rustAckCopy = rustAck
        return await context.perform { [rustAck = rustAckCopy] in
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            let found = (try? context.fetch(fetch))?.isEmpty == false
            if found {
                rustAck.markProcessed(messageId: messageId)
            }
            return found
        }
    }

    // MARK: - Mark

    /// Synchronous in-memory-only duplicate check — does NOT touch Core Data.
    ///
    /// Returns `true` only if `preemptACK` or `markProcessed` was called for this
    /// `messageId` in the current process lifetime.  Use this in hot paths (e.g. crypto
    /// failure guards) where a fast, I/O-free check is needed.
    ///
    /// A `false` result does NOT mean the message was never processed — it may simply
    /// not have been cached yet after an app restart.  Use `isProcessed(_:in:)` for a
    /// definitive answer that also consults Core Data.
    func isProcessedInMemory(_ messageId: String) -> Bool {
        if case .inCache = rustAck.isProcessed(messageId: messageId) { return true }
        return false
    }

    /// Immediately marks `messageId` as processed **in the in-memory Rust cache only** (no IO).
    ///
    /// Call this on the same thread as `decryptMessage` to close the race window with the
    /// live gRPC stream.  The stream's `isProcessed` check consults the in-memory cache first
    /// (`.inCache` → true), so this single call is sufficient to prevent double-decryption.
    ///
    /// Always follow up with `markProcessed(_:senderId:in:)` on the background thread to
    /// persist the ACK to Core Data across app restarts.
    func preemptACK(_ messageId: String) {
        rustAck.markProcessed(messageId: messageId)
    }

    /// Marks `messageId` as processed. Idempotent — safe to call multiple times.
    func markProcessed(_ messageId: String, senderId: String, in context: NSManagedObjectContext) {
        rustAck.markProcessed(messageId: messageId)

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
        rustAck.pruneExpired()

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
