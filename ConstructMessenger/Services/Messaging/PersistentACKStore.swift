//
//  PersistentACKStore.swift
//  Construct Messenger
//
//  Persistent acknowledgment store for processed messages.
//
//  Prevents duplicate message processing across app restarts caused by server
//  re-delivering unacknowledged messages on reconnect.
//
//  Architecture — one cache, one durable store:
//  - Hot path: the orchestrator's ACK cache, reached via `CryptoManager`. Process-lifetime only.
//  - Durable path: Core Data `ProcessedMessage` — the **owner** of dedup state, survives restart.
//  - TTL: entries older than `retentionDays` are pruned on app launch.
//
//  This type used to hold its own `RustAckStore`, a second in-memory cache independent of the
//  orchestrator's. The same question had two answers, written by different call sites and never
//  reconciled: the Rust decrypt path marked only the orchestrator's, `preemptACK` marked only
//  this one, and one site in `PublicKeyBundleHandler` wrote all three stores in a row under a
//  comment claiming the orchestrator cache "persists with the next state save" — it does not.
//  Removed 2026-08-02, see decisions/one-ack-cache-one-durable-store.md.

import Foundation
import CoreData

final class PersistentACKStore {

    static let shared = PersistentACKStore()

    /// Number of days to retain ACK entries. Matches server re-delivery window.
    static let retentionDays = 30

    private init() {}

    // MARK: - Cache access
    //
    // The single in-memory cache lives in the Rust orchestrator. When the core is not up
    // (pre-login, tests) every question falls through to Core Data, which is the owner.

    /// A miss and "the core is not up" are both `false` here: neither is an answer, and every
    /// caller either falls through to Core Data or is a hot-path guard that cannot run without
    /// the core anyway.
    private func isInCache(_ messageId: String) -> Bool {
        if case .inCache = CryptoManager.shared.ackIsProcessedInOrchestrator(messageId: messageId) {
            return true
        }
        return false
    }

    /// Warming is best-effort — the durable store is the owner. A skip is counted rather than
    /// silent: it means a durable ACK exists that the hot-path guard will not see this launch.
    private func warmCache(_ messageId: String) {
        guard CryptoManager.shared.isOrchestratorCoreUp else {
            PerformanceMetrics.shared.record(.ackCacheWarmSkippedNoCore, label: String(messageId.prefix(8)))
            return
        }
        CryptoManager.shared.markAckProcessedInOrchestrator(messageId: messageId)
    }

    // MARK: - Check

    /// Returns `true` if the message was already processed (cache or durable store).
    func isProcessed(_ messageId: String, in context: NSManagedObjectContext) -> Bool {
        if isInCache(messageId) { return true }
        return isProcessedInCoreData(messageId, in: context)
    }

    /// Async variant for Rust orchestrator `CheckAckInDb` callbacks.
    /// Queries Core Data on a background context without requiring the caller to supply one.
    func isProcessed(messageId: String) async -> Bool {
        if isInCache(messageId) { return true }
        return await isProcessedInCoreData(messageId: messageId)
    }

    /// Query ONLY Core Data — bypass the in-memory ACK cache.
    ///
    /// Use this exclusively in the `CheckAckInDb` handler. That question is "was this processed
    /// in a *prior* session?", and the cache cannot answer it: a mark made earlier in this same
    /// launch — by the Rust decrypt path or by `markProcessedInCache` ahead of the durable
    /// write — would answer `true` and turn a live message into a phantom duplicate.
    func isProcessedInCoreData(_ messageId: String, in context: NSManagedObjectContext) -> Bool {
        var found = false
        context.performAndWait {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            found = (try? context.fetch(fetch))?.isEmpty == false
        }
        if found { warmCache(messageId) }
        return found
    }

    /// Async Core-Data-only variant for the `CheckAckInDb` async callback path.
    /// Same rationale as `isProcessedInCoreData(_:in:)` — bypasses the cache.
    func isProcessedInCoreData(messageId: String) async -> Bool {
        let context = PersistenceController.shared.container.newBackgroundContext()
        let found = await context.perform {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1
            return (try? context.fetch(fetch))?.isEmpty == false
        }
        if found { warmCache(messageId) }
        return found
    }

    // MARK: - Mark

    /// Synchronous cache-only duplicate check — does NOT touch Core Data.
    ///
    /// Returns `true` only if the message was marked in the current process lifetime, by any
    /// writer: the Rust decrypt path, `markProcessedInCache`, or the warm-up after a durable
    /// hit. Use this in hot paths (e.g. crypto failure guards) where a fast, I/O-free check
    /// is needed.
    ///
    /// A `false` result does NOT mean the message was never processed — it may simply not be
    /// cached yet after a restart, or the core may not be up. Use `isProcessed(_:in:)` for a
    /// definitive answer that also consults the durable store.
    func isProcessedInMemory(_ messageId: String) -> Bool {
        isInCache(messageId)
    }

    /// Marks `messageId` as processed **in the cache only** (no IO).
    ///
    /// Call this on the same thread as `decryptMessage` to close the race window with the live
    /// gRPC stream: the stream's `isProcessed` check consults the cache first, so this single
    /// call is enough to prevent double-decryption.
    ///
    /// Always follow up with `markProcessed(_:senderId:in:)` to make the ACK survive a restart —
    /// this cache does not. Was `preemptACK`, renamed 2026-08-02 so the name says which of the
    /// two stores it writes.
    func markProcessedInCache(_ messageId: String) {
        warmCache(messageId)
    }

    /// Marks `messageId` as processed. Idempotent — safe to call multiple times.
    func markProcessed(_ messageId: String, senderId: String, in context: NSManagedObjectContext) {
        do {
            try markProcessedOrThrow(messageId, senderId: senderId, in: context)
        } catch {
            // Already logged in markProcessedOrThrow.
        }
    }

    func markProcessedOrThrow(_ messageId: String, senderId: String, in context: NSManagedObjectContext) throws {
        var saveError: Error?
        var shouldWarmCache = false

        context.performAndWait {
            let fetch = ProcessedMessage.fetchRequest()
            fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
            fetch.fetchLimit = 1

            if (try? context.fetch(fetch))?.isEmpty == false {
                shouldWarmCache = true
                return
            }

            let record = ProcessedMessage(context: context)
            record.messageId = messageId
            record.senderId = senderId
            record.processedAt = Date()

            do {
                try context.saveOrThrow(category: "PersistentACK")
                shouldWarmCache = true
            } catch {
                context.rollback()
                saveError = error
            }
        }

        if shouldWarmCache {
            warmCache(messageId)
        }

        if let saveError {
            Log.error("PersistentACKStore: failed to save ACK for \(messageId.prefix(8))…: \(saveError)", category: "PersistentACK")
            throw saveError
        }
    }

    // MARK: - Cleanup

    /// Deletes ACK entries older than `retentionDays`. Call once per app launch.
    ///
    /// Durable store only. The cache is not pruned and cannot be: its entries carry no
    /// timestamp, so there is nothing to age them by — it is bounded by process lifetime
    /// instead (`AckStore::prune_expired` in construct-core says the same). The old
    /// `rustAck.pruneExpired()` call here built a `PruneAckStore` action and dropped it.
    func pruneExpired(in context: NSManagedObjectContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date.distantPast
        let fetch = ProcessedMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "processedAt < %@", cutoff as NSDate)

        do {
            let expired = try context.fetch(fetch)
            if !expired.isEmpty {
                Log.info("PersistentACKStore: pruning \(expired.count) expired ACK(s)", category: "PersistentACK")
                expired.forEach { context.delete($0) }
                try context.save()
            }
        } catch {
            Log.error("PersistentACKStore: prune failed: \(error)", category: "PersistentACK")
        }
    }
}
