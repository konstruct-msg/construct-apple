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
//  - Durable path: `LocalRepositories.processedMessages` (`ProcessedMessageStore`) — the **owner**
//    of dedup state, survives restart.
//  - TTL: entries older than `retentionDays` are pruned on app launch.
//
//  This type used to hold its own `RustAckStore`, a second in-memory cache independent of the
//  orchestrator's. The same question had two answers, written by different call sites and never
//  reconciled: the Rust decrypt path marked only the orchestrator's, `preemptACK` marked only
//  this one, and one site in `PublicKeyBundleHandler` wrote all three stores in a row under a
//  comment claiming the orchestrator cache "persists with the next state save" — it does not.
//  Removed 2026-08-02, see decisions/one-ack-cache-one-durable-store.md.

import Foundation

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

    // MARK: - Durable-persistence expectations
    //
    // `CfeAction.persistAck` is documented in the core as "platform must durable-persist this
    // record" (`ack_store.rs:109`). The platform never did: the handler re-marked the orchestrator
    // — which cannot do anything, because `mark_processed` inserts into the cache *before* emitting
    // the action, so the second call always short-circuits — and recorded a metric on every
    // decrypted message. A counter that increments once per message measures traffic, not failure,
    // and is exactly what rule 1a of decisions/ios-semantic-divergence-signals forbids.
    //
    // The L2 write really does happen, just somewhere else: `MessageRouter`'s terminal paths. So
    // the action is not useless — it is the core stating an obligation that nothing checks. These
    // two calls turn it into one that is checked: the executor records the obligation, the router
    // settles it at the single point every routing pass exits through.

    private let expectationLock = NSLock()
    private var awaitingDurableWrite: Set<String> = []

    /// The core requires `messageId` to survive a restart as "processed".
    func expectDurableWrite(_ messageId: String) {
        expectationLock.lock()
        awaitingDurableWrite.insert(messageId)
        expectationLock.unlock()
    }

    /// Clear the obligation and report whether it is still outstanding.
    ///
    /// Returns `true` only when the core asked for a durable write during this pass and Core Data
    /// still does not have it. Callers use that to decide whether the pass ended in a real gap:
    /// the cursor moves on, the core's in-memory cache dies with the process, and the message comes
    /// back after a restart with nothing left that remembers handling it.
    func settleDurableWrite(_ messageId: String) -> Bool {
        expectationLock.lock()
        let wasExpected = awaitingDurableWrite.remove(messageId) != nil
        expectationLock.unlock()
        guard wasExpected else { return false }
        return !isProcessedDurably(messageId)
    }

    #if DEBUG
    func hasOutstandingDurableWriteForTesting(_ messageId: String) -> Bool {
        expectationLock.lock()
        defer { expectationLock.unlock() }
        return awaitingDurableWrite.contains(messageId)
    }

    func resetDurableWriteExpectationsForTesting() {
        expectationLock.lock()
        awaitingDurableWrite.removeAll()
        expectationLock.unlock()
    }
    #endif

    // MARK: - Check

    /// Returns `true` if the message was already processed (cache or durable store).
    func isProcessed(_ messageId: String) -> Bool {
        if isInCache(messageId) { return true }
        return isProcessedDurably(messageId)
    }

    /// Query ONLY the durable store — bypass the in-memory ACK cache.
    ///
    /// Use this exclusively in the `CheckAckInDb` handler. That question is "was this processed
    /// in a *prior* session?", and the cache cannot answer it: a mark made earlier in this same
    /// launch — by the Rust decrypt path or by `markProcessedInCache` ahead of the durable
    /// write — would answer `true` and turn a live message into a phantom duplicate.
    ///
    /// A store that does not answer reads as "not processed": a duplicate is then caught by the
    /// ratchet (its key is spent), where a false "processed" would drop a live message.
    func isProcessedDurably(_ messageId: String) -> Bool {
        let found: Bool
        do {
            found = try LocalRepositories.processedMessages.isProcessed(messageId)
        } catch {
            Log.error("PersistentACKStore: durable check failed for \(messageId.prefix(8))…: \(error)", category: "PersistentACK")
            found = false
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
    func markProcessed(_ messageId: String, senderId: String) {
        do {
            try markProcessedOrThrow(messageId, senderId: senderId)
        } catch {
            // Already logged in markProcessedOrThrow.
        }
    }

    func markProcessedOrThrow(_ messageId: String, senderId: String) throws {
        do {
            try LocalRepositories.processedMessages.markProcessed(messageId, senderId: senderId, at: Date())
        } catch {
            Log.error("PersistentACKStore: failed to save ACK for \(messageId.prefix(8))…: \(error)", category: "PersistentACK")
            throw error
        }
        // Warmed whether the mark was new or already held: either way it is durable now.
        warmCache(messageId)
    }

    // MARK: - Cleanup

    /// Deletes ACK entries older than `retentionDays`. Call once per app launch.
    ///
    /// Durable store only. The cache is not pruned and cannot be: its entries carry no
    /// timestamp, so there is nothing to age them by — it is bounded by process lifetime
    /// instead (`AckStore::prune_expired` in construct-core says the same). The old
    /// `rustAck.pruneExpired()` call here built a `PruneAckStore` action and dropped it.
    func pruneExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date.distantPast
        do {
            let pruned = try LocalRepositories.processedMessages.forget(processedBefore: cutoff)
            if pruned > 0 {
                Log.info("PersistentACKStore: pruned \(pruned) expired ACK(s)", category: "PersistentACK")
            }
        } catch {
            Log.error("PersistentACKStore: prune failed: \(error)", category: "PersistentACK")
        }
    }
}
