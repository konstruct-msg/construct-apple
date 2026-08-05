//
//  MessageRouter.swift
//  Construct Messenger
//
//  Pure incoming-message pipeline: validate → decrypt via Rust orchestrator → dispatch
//  typed events to MessageRouterDelegate (SessionCoordinator).
//
//  Owns PendingSessionQueue — messages that arrived before their sender's DR session
//  was ready. SessionCoordinator drains the queue after successful session init/heal.
//

import Foundation
import CoreData
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class MessageRouter {

    // MARK: - Delegate + queue

    weak var delegate: (any MessageRouterDelegate)?

    /// Messages pending session establishment, keyed by sender userId.
    /// SessionCoordinator drains this via `drainPendingMessages(for:)` after init/heal.
    let pendingQueue = PendingSessionQueue()

    // MARK: - Core Data

    private var viewContext: NSManagedObjectContext?

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    private let chunkReassembler = ChunkedMessageReassembler.shared
    private var processingMessageIds: Set<String> = []

    /// Opens the SealedInner at the STEALTH boundary in `routeIncomingMessage`. Injected rather
    /// than reached through `StealthSenderService.shared` so the post-unseal routing decisions
    /// are drivable without Keychain identity keys or a genuine sealed box.
    ///
    /// The dependency is explicit because this boundary is where `f39e03b4` broke: the recovered
    /// `contentType` must be remapped into the routing kind, and *nothing* could execute that
    /// line under test — sealed END_SESSION / SESSION_RESET_INIT were dropped in production for
    /// four days with the whole suite green.
    var sealedSenderResolver: any SealedSenderResolving = StealthSenderService.shared

    /// Message ids that already consumed their one unseal-failure redelivery
    /// (sealed-sender-resilience lever A). First unseal failure defers (holds the
    /// cursor → server re-delivers once); a second failure for the same id gives up and
    /// drops. Bounded so a flood of undecryptable boxes can't grow it without limit.
    private var unsealDeferredIds: [String] = []
    private func consumeUnsealRetry(_ id: String) -> Bool {
        if unsealDeferredIds.contains(id) { return false } // already retried → give up
        unsealDeferredIds.append(id)
        if unsealDeferredIds.count > 512 { unsealDeferredIds.removeFirst() }
        return true // first failure → allow one redelivery
    }

    /// Refreshes the cached bundle-signing key off the hot path when a sealed message
    /// arrived unvouched or unsealable — likely a missing/stale key. `fetchAndCacheRelayConfig`
    /// caches the bundle key before the relay guard, so this works even when VEIL is inactive
    /// (sealed-sender-resilience lever B: decoupled from the VEIL fetch). Debounced to at most
    /// once a minute so a burst of such messages can't spam the network.
    private var lastBundleKeyRefresh: Date = .distantPast
    private func refreshBundleKeyIfStale() {
        guard Date().timeIntervalSince(lastBundleKeyRefresh) > 60 else { return }
        lastBundleKeyRefresh = Date()
        Task { _ = await VeilCertFetcher.shared.fetchAndCacheRelayConfig() }
    }

    /// Per-contact throttle for the "session out of sync" system message. A broken peer can
    /// deliver a burst of mid-ratchet messages (msgNum>0 with no session), each of which would
    /// otherwise insert a fresh system bubble AND ask the sender to restart — the visible storm.
    /// Matches SessionCoordinator's END_SESSION cooldown (30s) so the notice and the restart
    /// request fire together, at most once per window.
    private var outOfSyncNoticeAt: [String: Date] = [:]
    private static let outOfSyncNoticeCooldown: TimeInterval = 30.0
    private func shouldEmitOutOfSyncNotice(for userId: String) -> Bool {
        let now = Date()
        if let last = outOfSyncNoticeAt[userId], now.timeIntervalSince(last) < Self.outOfSyncNoticeCooldown {
            return false
        }
        outOfSyncNoticeAt[userId] = now
        return true
    }

    /// Receive-side coalesce for END_SESSION storms (server re-delivers dozens of control msgs for
    /// one peer per reconnect). First handle wins; rest are ACK-only. SESSION_RESET_INIT is NOT
    /// coalesced by this time window — it carries a fresh X3DH init and is filtered by content
    /// freshness instead (`isResetInitSuperseded`); a handled SRI still arms this window so a
    /// trailing END_SESSION for the same reset is coalesced.
    private var lastInboundEndSessionAt: [String: Date] = [:]
    /// Long enough to cover a full pending-queue flush + stream reconnect without re-tearing
    /// a session we just rebuilt; short enough that a real second reset later still lands.
    private static let inboundControlCooldown: TimeInterval = 45.0

    private func shouldHandleInboundEndSession(for userId: String) -> Bool {
        let now = Date()
        guard SessionReducer.shouldHandleInboundControl(
            lastHandledAt: lastInboundEndSessionAt[userId],
            now: now,
            cooldown: Self.inboundControlCooldown
        ) else { return false }
        lastInboundEndSessionAt[userId] = now
        return true
    }

    // MARK: - Queue access for SessionCoordinator

    /// Drain and return all pending messages for `userId` (clears the queue as a side-effect).
    func drainPendingMessages(for userId: String) -> [ChatMessage] {
        pendingQueue.drain(for: userId)
    }

    /// Clear pending messages for `userId` (e.g. after heal failure). This is a give-up:
    /// resolve each discarded message in the cursor tracker so its held watermark is released
    /// (we will never persist it; matches the pre-existing drop-and-advance behaviour).
    func removePendingMessages(for userId: String) {
        let discarded = pendingQueue.drain(for: userId)
        for msg in discarded {
            StreamCursorTracker.shared.resolve(messageId: msg.id)
        }
    }

    // MARK: - Tie-break confirm hold

    /// Hold `message` until the tie-break confirm gate for `userId` resolves — peer ack or
    /// watchdog give-up, both of which call `replayHeldMessages(for:in:)`.
    ///
    /// Returns the cursor disposition, and deliberately never marks the message processed: a held
    /// message must stay redeliverable. Giving that up is what turned a decrypt failure inside the
    /// confirm window into permanent loss rather than a delay.
    private func holdUntilConfirmResolves(
        _ message: ChatMessage,
        from userId: String,
        reason: String
    ) -> StreamCursorTracker.Outcome {
        if pendingQueue.contains(messageId: message.id, for: userId) { return .deferred }
        guard pendingQueue.enqueue(message, for: userId) else {
            // Cap reached (100/peer). Now it really is a drop, so say so at ERROR — the one
            // branch in this path where a message is lost on purpose.
            Log.error("SESSION_STATE[confirm_hold_overflow]: buffer full for \(userId.prefix(8))… — dropping \(message.id.prefix(8))… (\(reason))", category: "MessageRouter")
            PerformanceMetrics.shared.record(.confirmHoldOverflow, label: reason)
            return .durable
        }
        // Stamp the session this was held *against*. Without it the replay cannot tell an init
        // that is still live from one a later handshake has already replaced — see
        // SessionReducer.heldReplayDisposition.
        heldAgainstEpoch[message.id] = CryptoManager.shared.sessionEpoch(for: userId)
        Log.info("SESSION_STATE[confirm_hold]: holding msgNum=\(message.messageNumber) from \(userId.prefix(8))… (\(reason)) — buffer \(pendingQueue.count(for: userId))", category: "MessageRouter")
        PerformanceMetrics.shared.record(.confirmHold, label: reason)
        return .deferred
    }

    /// The `SessionEpoch` each held message was set aside against, keyed by message id.
    /// Cleared as the buffer drains; a held message that never returns takes its entry with it
    /// through the overflow path.
    private var heldAgainstEpoch: [String: SessionEpoch?] = [:]

    /// Re-route everything held behind the tie-break confirm gate for `userId`.
    ///
    /// Only meaningful once the gate is down: with it still up every message would be re-held and
    /// the drain would be a no-op that read like a flush, so the gate state is asserted here rather
    /// than trusted from the call site.
    func replayHeldMessages(for userId: String, in context: NSManagedObjectContext) {
        guard !SessionConfirmationTracker.shared.isPending(userId) else {
            let held = pendingQueue.count(for: userId)
            if held > 0 {
                Log.info("SESSION_STATE[confirm_replay_skipped]: gate still up for \(userId.prefix(8))… — \(held) message(s) stay held", category: "MessageRouter")
            }
            return
        }
        let held = pendingQueue.drain(for: userId)
        guard !held.isEmpty else { return }
        let current = CryptoManager.shared.sessionEpoch(for: userId)
        var replayed = 0
        var superseded = 0
        for message in held {
            let heldAgainst = heldAgainstEpoch.removeValue(forKey: message.id) ?? nil
            switch SessionReducer.heldReplayDisposition(
                heldAgainst: heldAgainst,
                current: current,
                isPeerInit: message.messageNumber == 0
            ) {
            case .replay:
                replayed += 1
                routeIncomingMessage(message, in: context)
            case .superseded:
                // Acknowledge: it will never decrypt, and leaving it unacked means the server
                // redelivers it forever — the amplifier behind the receipt storm. Dropping it
                // silently is what it must NOT do, hence the count in the line below.
                superseded += 1
                PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                StreamCursorTracker.shared.resolve(messageId: message.id)
                PerformanceMetrics.shared.record(.confirmReplaySuperseded, label: "peer_init")
            }
        }
        Log.info(
            "SESSION_STATE[confirm_replay]: \(replayed) re-routed, \(superseded) superseded of \(held.count) held from \(userId.prefix(8))…",
            category: "MessageRouter"
        )
    }

    private func beginProcessing(_ messageId: String) -> Bool {
        processingMessageIds.insert(messageId).inserted
    }

    private func endProcessing(_ messageId: String) {
        processingMessageIds.remove(messageId)
    }

    // MARK: - Message Routing
    
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        // Stream-cursor disposition. Default `.durable` (message persisted / control handled /
        // given up → safe to advance the resume cursor). A queued-for-session-init or transient
        // terminal sets `.deferred` (hold the watermark); a duplicate/not-ready exit sets `.skip`
        // (let the owning path resolve it). The defer reports exactly once on every exit path.
        // Untracked ids (backfill, which carries no stream cursor) are no-ops in the tracker.
        var streamOutcome: StreamCursorTracker.Outcome = .durable
        defer {
            // Settle the core's durable-persistence obligation at the one point every exit path
            // passes through. Only `.durable` is a verdict: it says nothing will revisit this
            // message, so if the core asked for a durable record and Core Data has none, the
            // record exists solely in a cache that dies with the process — after a restart the
            // message returns and nothing remembers handling it. `.deferred` and `.skip` mean some
            // other path still owns it, and an obligation outstanding there is not yet a gap.
            let unmet = PersistentACKStore.shared.settleDurableWrite(message.id, in: context)
            if unmet, case .durable = streamOutcome {
                Log.error(
                    "PersistAck unmet for \(message.id.prefix(8))… — core required a durable record, the pass ended .durable with none written; a restart will re-deliver this message with nothing remembering it",
                    category: "MessageRouter"
                )
                PerformanceMetrics.shared.record(
                    .persistAckWithoutDurableWrite,
                    label: "msgNum=\(message.messageNumber)"
                )
            }
            StreamCursorTracker.shared.report(messageId: message.id, streamOutcome)
        }

        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            streamOutcome = .skip
            return
        }

        // STEALTH: resolve sender from sealed inner before any routing.
        // `from` is empty for ConstructSEALED messages — decrypt to recover sender ID.
        var message = message
        if message.from.isEmpty && !message.sealedInnerData.isEmpty {
            guard let resolved = sealedSenderResolver.resolveSender(sealedInnerBytes: message.sealedInnerData) else {
                // Unseal itself failed — no sender/payload recoverable (sealed-sender-resilience
                // lever A: this is the ONLY sealed drop). Give it one redelivery (a box that
                // fails to open right after an identity-key rotation deserves a second chance)
                // before dropping for good, instead of the old instant permanent loss.
                PerformanceMetrics.shared.record(.stealthUnsealFailure, label: "routeIncomingMessage")
                if consumeUnsealRetry(message.id) {
                    Log.error("STEALTH: unseal failed for \(message.id.prefix(8))… — deferring for one redelivery", category: "MessageRouter")
                    PerformanceMetrics.shared.record(.stealthUnsealDefer, label: "routeIncomingMessage")
                    refreshBundleKeyIfStale()
                    streamOutcome = .deferred
                } else {
                    Log.error("STEALTH: unseal failed again for \(message.id.prefix(8))… — dropping", category: "MessageRouter")
                    streamOutcome = .durable
                }
                return
            }

            // Unseal succeeded — sender + payload recovered. Attestation only tags trust;
            // an unvouched sender is still delivered (the ratchet is the real auth) and
            // self-heals the bundle-key cache for next time.
            if case .unvouched(let reason) = resolved.trust {
                Log.info("STEALTH: delivering UNVOUCHED sender \(resolved.senderId.prefix(8))… (\(reason))", category: "MessageRouter")
                PerformanceMetrics.shared.record(.stealthUnvouchedDelivery, label: "\(reason)")
                if reason != .expired {
                    // .badSignature / .noKey most likely mean a missing/stale bundle key —
                    // refresh it off the hot path so the next message re-vouches.
                    refreshBundleKeyIfStale()
                }
            }

            // The unseal boundary. `contentType` is the only type the message carries, so the
            // predicates that route it (isEndSession / isSessionResetInit / …) cannot disagree
            // with it any more. Copying the outer "DIRECT_MESSAGE" stamp into a parallel field
            // is what left those predicates false after sealed delivery
            // (SEALED_CONTROL_CHANNEL_REMEDIATION); the field is gone as of 2026-08-02.
            let recoveredKind = ContentTypeRouting.kind(for: resolved.contentType)  // log only
            message = message.resolvingSealedSender(resolved, currentUserId: currentUserId)
            Log.debug(
                "STEALTH: resolved sender → \(resolved.senderId.prefix(8))… ct=\(resolved.contentType) kind=\(recoveredKind.rawValue)",
                category: "MessageRouter"
            )
            // Nothing branches on `resolved.contentType` beyond this point for the four types that
            // moved into the frame (12/14/25/26) — it is UNSPECIFIED for all of them now. Only
            // END_SESSION (21) and SESSION_RESET_INIT (24) still say anything here.
        }

        let otherUserId = message.from == currentUserId ? message.to : message.from

        guard beginProcessing(message.id) else {
            Log.debug("Skipping in-flight duplicate \(message.id.prefix(8))…", category: "MessageRouter")
            // The concurrent in-flight processing owns this message's cursor outcome.
            streamOutcome = .skip
            return
        }
        defer { endProcessing(message.id) }

        // Locked-device guard. When the app is woken by a push while the screen is locked,
        // the device key material (signing/identity/prekeys) can be unreadable, so
        // OrchestratorCore never gets built (`coreNotInitialized`). We can neither decrypt
        // nor init a session. DEFER: hold the stream cursor, do NOT ACK and do NOT send
        // END_SESSION — the server re-delivers and we process once unlocked + core is ready.
        // This is the fix for the "Encrypted session out of sync" desync: previously a
        // locked-launch incoming with no session tore down a perfectly healthy session.
        // Mirrors AuthViewModel's "defer recovery to foreground" behaviour.
        if !CryptoManager.shared.isInitialized {
            Log.info("Core not initialized (device likely locked) — deferring incoming \(message.id.prefix(8))… (no ACK, no END_SESSION)", category: "MessageRouter")
            streamOutcome = .deferred
            return
        }

        #if DEBUG
        Log.debug("INCOMING message RAW from server:", category: "MessageRouter")
        Log.debug("   messageId: \(message.id)", category: "MessageRouter")
        Log.debug("   from: \(message.from)", category: "MessageRouter")
        Log.debug("   to: \(message.to)", category: "MessageRouter")
        Log.debug("   messageNumber: \(message.messageNumber)", category: "MessageRouter")
        Log.debug("   oneTimePreKeyId: \(message.oneTimePreKeyId)", category: "MessageRouter")
        Log.debug("   ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "MessageRouter")
        Log.debug("   ephemeralPublicKey preview: \(message.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "MessageRouter")
        Log.debug("   content (padded): \(message.content.count) bytes", category: "MessageRouter")
        Log.debug("   content preview: \(message.content.prefix(16).map { String(format: "%02x", $0) }.joined())…", category: "MessageRouter")
        Log.debug("   isEndSession: \(message.isEndSession)", category: "MessageRouter")
        #endif
        
        // 1. Skip if already processed — applies to ALL messages including END_SESSION.
        //    Without this, the same END_SESSION is processed twice (pending queue + stream).
        //
        //    Exception: if this is a session init (msgNum=0) and we have no active session
        //    for the sender, re-process it. This handles the crash-recovery scenario where
        //    the init was ACKed before the session was persisted (e.g., app crashed mid-init).
        if PersistentACKStore.shared.isProcessed(message.id, in: context) {
            // Orphaned-init exception: re-process msgNum=0 when the session was lost
            // after ACK (e.g. app crashed between ACK and session persist). But exclude
            // messages that have already been through initReceivingSession and failed
            // (OTPK consumed, key mismatch, etc.) — those can never succeed and would
            // loop on every reconnect if we keep re-processing them.
            // Never re-process control carriers as "orphaned init" — END_SESSION / SRI /
            // sender-sync already failed or completed; replaying them loops session teardown.
            let isOrphanedInit = message.messageNumber == 0
                && !message.isEndSession
                && !message.isSessionResetInit
                && !message.isSenderSync
                && !CryptoManager.shared.hasSession(for: otherUserId)
                && !FailedInitMessageStore.shared.contains(message.id)
            if !isOrphanedInit {
                Log.debug("Skipping already-processed message \(message.id.prefix(8))… (ACK store)", category: "MessageRouter")
                // The message IS in the transcript from the first delivery, and re-sending the
                // receipt is still the only thing that can move the sender's checkmark off "sent"
                // if our first one was lost. But once per *redelivery* is an amplifier: a receipt
                // is itself a message, so it enters the peer's stream, gets replayed back at us by
                // the server, and is answered again. On 2026-08-04 that turned 6236 duplicates
                // into 3754 encrypt+ratchet+RPC cycles and cooked the phone.
                //
                // Once per message per window keeps the recovery and removes the loop: a lost
                // receipt is cosmetic and rare, and receipts do not stop redelivery anyway — the
                // stream cursor does.
                if ReceiptResendThrottle.shared.shouldSend(messageId: message.id) {
                    OutboundSessionService.sendDeliveryReceipt(for: [message.id], to: otherUserId, in: context)
                } else {
                    PerformanceMetrics.shared.record(.receiptResendThrottled, label: "duplicate_delivery")
                }
                return
            }
            Log.info("Re-processing orphaned session init \(message.id.prefix(8))… (no active session for \(otherUserId.prefix(8))…)", category: "MessageRouter")
        }

        // 2. SENDER_SYNC — copy of own outgoing message from another device.
        //    Route separately: decrypt with per-device session, save as outgoing in the
        //    conversation with the original partner (extracted from conversationId).
        if message.isSenderSync {
            PersistentACKStore.shared.markProcessed(message.id, senderId: message.from, in: context)
            handleSenderSync(message, in: context)
            return
        }

        // 3a. SESSION_RESET_INIT: atomic archive of old session + RESPONDER init in one step.
        //     Must be checked BEFORE the END_SESSION path (it carries a real X3DH payload).
        if message.isSessionResetInit {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            // Coalesce by *content freshness*, not a blanket time window: a SESSION_RESET_INIT
            // carries a fresh X3DH init, so only one that pre-dates/exactly-matches our current
            // establishment (a server backlog replay) is a duplicate to ACK-only. A *newer* init
            // is a live re-init and MUST be applied even while a session is active — dropping it
            // strands the RESPONDER on a dead ratchet → END_SESSION storm (2026-07-26 desync).
            if delegate?.messageRouter(
                self,
                isResetInitSuperseded: otherUserId,
                timestamp: message.timestamp,
                initEphemeral: message.ephemeralPublicKey
            ) == true {
                Log.info(
                    "SESSION_RESET_INIT superseded for \(otherUserId.prefix(8))… — ACK only (pre-dates current session)",
                    category: "MessageRouter"
                )
                return
            }
            Log.info("SESSION_RESET_INIT from \(otherUserId.prefix(8))…", category: "MessageRouter")
            handleSessionResetInit(message: message, from: otherUserId, in: context)
            // A handled SRI also counts as "we just reset this peer" for the END_SESSION coalescer
            // (preserves the cross-arm the removed inbound-control time-window provided).
            lastInboundEndSessionAt[otherUserId] = Date()
            return
        }

        // 3. Check if this is an END_SESSION control message
        if message.isEndSession {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            // Typed reason hint (if the sender is new enough to attach a SessionControl payload):
            // .otpkUnreproducible means the peer, as our RESPONDER, could not reproduce the 4-DH
            // OTPK our last X3DH used. Re-initiating with another OTPK would loop, so mark the peer
            // to force a 3-DH re-init (no OTPK) on our next session init. Legacy END_SESSION carries
            // a 16-byte sentinel that simply won't decode → no hint, default behaviour preserved.
            if !message.rawPayload.isEmpty,
               let control = try? Shared_Proto_Messaging_V1_SessionControl(serializedBytes: message.rawPayload),
               control.reason == .otpkUnreproducible {
                Log.info("END_SESSION from \(otherUserId.prefix(8))… hints OTPK-unreproducible — forcing 3-DH re-init", category: "MessageRouter")
                SessionReinitHintStore.shared.requestThreeDHReinit(for: otherUserId)
            }
            if !shouldHandleInboundEndSession(for: otherUserId) {
                Log.info(
                    "END_SESSION coalesced for \(otherUserId.prefix(8))… — ACK only (inbound control cooldown)",
                    category: "MessageRouter"
                )
                return
            }
            Log.info("Received END_SESSION from \(otherUserId)", category: "MessageRouter")
            handleEndSession(from: otherUserId, messageTimestamp: message.timestamp, in: context)
            return
        }

        // 3. Skip if already saved to Core Data (deduplication for duplicate deliveries)
        let existingFetch = Message.fetchRequest()
        existingFetch.predicate = NSPredicate(format: "id == %@", message.id)
        existingFetch.fetchLimit = 1
        do {
            if try context.fetch(existingFetch).first != nil {
                Log.debug("Skipping already-saved message \(message.id.prefix(8))…", category: "MessageRouter")
                return
            }
        } catch {
            Log.error("Failed to deduplicate incoming message \(message.id.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        // 4. Handle messages from contacts whose chat was explicitly deleted.
        //    messageNumber=0 means the sender fetched our *current* public keys (via a fresh invite)
        //    and started a new session — this is a legitimate re-contact, so clear the deleted flag
        //    and process normally (a new chat will be created by findOrCreateChat below).
        //    messageNumber>0 is an old broken session we no longer have keys for — skip it.
        //    Exception: if this exact message is already in our pending queue (a previous heal
        //    attempt started and failed), the server is re-delivering a stuck undecryptable message.
        //    Do NOT resurrect the contact in that case — just ACK and discard.
        if DeletedContactsStore.shared.isDeleted(otherUserId) {
            if message.messageNumber == 0 {
                // Guard: don't resurrect a deleted contact for a message we already queued
                // but couldn't decrypt. This prevents an infinite delete→re-appear loop when
                // the server keeps re-delivering stuck undecryptable messages.
                if pendingQueue.contains(messageId: message.id, for: otherUserId) {
                    Log.debug("Skipping stale pending message \(message.id.prefix(8))… from deleted contact — not resurrecting", category: "MessageRouter")
                    PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "stale_pending")
                    return
                }
                Log.info("Fresh session (msgNum=0) from previously-deleted contact \(otherUserId.prefix(8))… — clearing deleted flag", category: "MessageRouter")
                DeletedContactsStore.shared.remove(otherUserId)
                // Fall through to normal processing below.
            } else {
                Log.debug("Skipping old-session message (msgNum=\(message.messageNumber)) from deleted contact \(otherUserId.prefix(8))…", category: "MessageRouter")
                return
            }
        }

        // 5. Find or create chat
        let chat: Chat
        let isNewChat: Bool
        do {
            (chat, isNewChat) = try findOrCreateChat(for: otherUserId, in: context)
        } catch {
            Log.error("Failed to resolve chat for \(otherUserId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }
        
        // 6. Check if we have a session for this user.
        // Guard against startup race: the deferred restoreRecentSessions() may not have run yet
        // if Core Data wasn't ready. Calling restoreSession(for:) here is a targeted, synchronous
        // Keychain load for exactly this contact — a no-op if already in memory (~1µs), or a fast
        // import (~5-10ms) if the session key is in Keychain but not yet loaded into the Rust core.
        // This prevents the false "session out of sync" banner that fires when the gRPC stream
        // delivers a mid-ratchet message (msgNum > 0) before sessions have been fully restored.
        CryptoManager.shared.restoreSession(for: otherUserId)
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)
        Log.info("SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")
        
        if !hasSession {
            // First message from this user - need to initialize receiving session.
            // handleFirstMessage decides whether the message was queued (.deferred → hold the
            // cursor until drained) or is a give-up (.durable → may advance).
            streamOutcome = handleFirstMessage(
                message,
                from: otherUserId,
                chat: chat,
                isNewChat: isNewChat,
                in: context
            )
            return
        }

        // Guard: after a tie-break WIN we sent SESSION_RESET_INIT and are waiting for the
        // RESPONDER (peer) to acknowledge. A msgNum=0 arriving in this window is a peer init
        // encrypted under keys our fresh INITIATOR session cannot read, so feeding it to the
        // ratchet produces sendEndSession → reset loop.
        //
        // It is HELD, not discarded. The premise the discard rested on — "any msgNum=0 in this
        // window is the peer's OLD attempt" — was false on 2026-08-04: the peer had genuinely
        // re-inited one second earlier, and `markProcessed` meant the server never redelivered
        // its init. Whether a peer init is stale or live is knowable only once the gate falls;
        // until then the message is buffered rather than guessed about.
        let gateIsUp = SessionConfirmationTracker.shared.isPending(otherUserId)
        // The gate can also fall inside that query, via its lazy TTL, and that path has no way to
        // replay what it released — it runs from whatever call site happened to ask, with no
        // managed-object context. It also beats the watchdog to the entry, so the `.giveUp` replay
        // never runs (observed in build 575: two peer inits held, zero replayed, cursor deferred
        // behind them). Settle it here, where the gate matters and a context exists.
        if !gateIsUp, SessionConfirmationTracker.shared.consumeLapse(otherUserId) {
            replayHeldMessages(for: otherUserId, in: context)
        }
        if case .hold = SessionReducer.confirmGateAction(
            isPending: gateIsUp,
            isControlCarrier: message.isEndSession || message.isSessionResetInit,
            isPeerInit: message.messageNumber == 0,
            decryptFailed: false
        ) {
            streamOutcome = holdUntilConfirmResolves(message, from: otherUserId, reason: "peer_init")
            if isNewChat { context.delete(chat) }
            return
        }

        // Rust orchestrator is the SINGLE decrypt path — no Swift fallback.
        // Изъян 4: If orchestratorCore is nil (e.g. Keychain locked after reboot),
        // attempt a one-shot reload before giving up and triggering END_SESSION.
        if CryptoManager.shared.orchestratorCore == nil {
            Log.info("OrchestratorCore nil — attempting reload before END_SESSION", category: "MessageRouter")
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        guard CryptoManager.shared.orchestratorCore != nil else {
            Log.error("OrchestratorCore still nil after reload — requesting END_SESSION from \(otherUserId.prefix(8))…", category: "MessageRouter")
            delegate?.messageRouter(self, needsEndSession: otherUserId)
            if isNewChat { context.delete(chat) }
            // Transient (Keychain locked / core not loaded): don't advance — let the server
            // re-deliver after the core recovers rather than acking an unprocessed message.
            streamOutcome = .deferred
            return
        }
        guard let event = buildIncomingEvent(message: message, otherUserId: otherUserId) else {
            Log.error("Cannot build incoming event for \(message.id.prefix(8))… — skipping", category: "MessageRouter")
            if isNewChat { context.delete(chat) }
            return
        }

        var actions: [CfeAction]
        do {
            PerformanceMetrics.shared.messageDecryptStart(messageId: message.id)
            actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "incoming_message")
            PerformanceMetrics.shared.messageDecryptEnd(messageId: message.id)
        } catch {
            Log.error("handleEvent threw for \(message.id.prefix(8))…: \(error) — sending END_SESSION", category: "MessageRouter")
            // Mark as processed so BackgroundFetch does not re-process this undecryptable message
            // on every background cycle (which would recreate ghost contacts and cause Core Data
            // validation errors). The failed receipt + END_SESSION handle recovery on the live stream.
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            delegate?.messageRouter(self, needsEndSession: otherUserId)
            if isNewChat { context.delete(chat) }
            return
        }

        // The action list is a set, not a single verdict — read it by name, never by position or
        // length. See OrchestratorActionPlan for what `actions.count == 1` used to cost us here.
        let plan = OrchestratorActionPlan(actions: actions)

        // Handle checkAckInDb round-trip synchronously (Rust ACK cache miss after restart).
        // Rust asks whenever its in-memory cache misses; Swift checks Core Data and feeds back
        // ackDbResult so Rust can decide whether to decrypt or drop the message.
        if let ackMsgId = plan.ackCheckMessageId {
            let isProcessed = PersistentACKStore.shared.isProcessedInCoreData(ackMsgId, in: context)
            let ackResult = CfeIncomingEvent.ackDbResult(messageId: ackMsgId, isProcessed: isProcessed)
            let followup: [CfeAction]
            do {
                followup = try CryptoManager.shared.handleOrchestratorEvent(ackResult, tag: "ack_db_result")
            } catch {
                Log.error("ACK DB result follow-up failed for \(ackMsgId.prefix(8))…: \(error)", category: "MessageRouter")
                if isNewChat { context.delete(chat) }
                return
            }

            // An empty follow-up is a VERDICT, not a missing answer. The core maps
            // `RoutingDecision::Duplicate` to `vec![]` (orchestrator.rs:1669), and the previous
            // `if !followup.isEmpty { actions = followup }` read that as "nothing came back, keep
            // what we had" — so `actions` still held the pre-round-trip `[checkAckInDb]` and the
            // loop below reported a correctly-dropped duplicate as "no routing decision … NOT
            // acked, no row written", printing the one action it had in fact just answered.
            // 6296 of 6302 fallthroughs in the 2026-08-04 run were this. One carrier, two
            // assertions ("what the core asked" vs "what the core decided") — the epic's own
            // defect class, sitting on the detector meant to catch it.
            switch AckCheckOutcome.resolve(followupIsEmpty: followup.isEmpty,
                                           weAnsweredProcessed: isProcessed) {
            case .routable:
                actions = followup

            case .duplicate:
                Log.debug(
                    "Duplicate confirmed by ACK DB check — \(ackMsgId.prefix(8))… msgNum=\(message.messageNumber), dropped without a row",
                    category: "MessageRouter"
                )
                PerformanceMetrics.shared.record(
                    .duplicateAfterAckCheck,
                    label: "msgNum=\(message.messageNumber)"
                )
                if isNewChat { context.delete(chat) }
                return

            case .droppedPendingRedelivery:
                // Init lock or cooldown: the message is dropped and comes back only by redelivery.
                // `streamOutcome` is deliberately left `.durable` — see the metric doc; changing
                // the cursor policy before we know this ever fires would make a zero unreadable
                // ("never happens" vs "we stopped counting it").
                Log.error(
                    "ACK DB check resumed with no routing decision for \(ackMsgId.prefix(8))… msgNum=\(message.messageNumber) — core returned no actions although we answered not-processed (init lock or END_SESSION cooldown); holding the cursor for redelivery",
                    category: "MessageRouter"
                )
                PerformanceMetrics.shared.record(
                    .ackCheckResumedWithoutDecision,
                    label: "msgNum=\(message.messageNumber)"
                )
                // The measurement this counter was added for came back on 2026-08-05 (build 577):
                // five ordinary message bodies, msgNum 0-3, dropped here inside one session
                // re-establishment — and none of them ever appears again in the log. The line said
                // "pending redelivery" while the cursor said `.durable`, i.e. done; the watermark
                // advanced past them and the server had nothing left to redeliver. Two carriers of
                // one intent, disagreeing in silence.
                //
                // `.deferred` is safe here precisely because both causes of an empty verdict — the
                // init lock and the END_SESSION cooldown — are transient by construction, and both
                // are released by the same paths that end a re-establishment. A permanent stall
                // would need the core to hold the init lock forever, which is its own bug and would
                // now be visible as a stuck watermark rather than as vanished messages.
                streamOutcome = .deferred
                if isNewChat { context.delete(chat) }
                return
            }
        }

        for action in actions {
            switch action {
            case .messageDecrypted:
                // Disposition is observed for metrics/signals only. Incomplete multi-chunk must
                // NOT hold the stream watermark (one partial media message would stall every
                // later cursor for the device). Reassembly that never completes is reported by
                // `.chunkReassemblyExpired`; durable reassembly is the real fix.
                _ = executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
                applyIncomingPqContribution(plan.kemCiphertext, for: message, contactId: otherUserId)
                return
            case .callSignalDecrypted:
                // ct=12: Rust decrypted the call signal — dispatch to CallManager directly.
                // There is no .messageDecrypted in the action list for call signals, so this
                // case must be handled here before the loop falls through to "no routing decision".
                _ = executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
                return
            case .sessionHealNeeded(let contactId, let role):
                handleRustHealDecision(role: role, contactId: contactId, message: message, in: context)
                if isNewChat { context.delete(chat) }
                // Queued for heal — hold the cursor until heal drains (success) or clears (give-up).
                streamOutcome = .deferred
                return
            case .sendEndSession(let contactId):
                // While our own SESSION_RESET_INIT is still unacked we are the side that replaced
                // the session; the peer is necessarily behind. A decrypt failure here is the
                // expected consequence of our own re-init, not evidence that the ratchet diverged,
                // and tearing down answers our own reset with another reset — taking the message
                // with it. 2026-08-04: a user's first message after a re-init died on exactly this
                // line, one second after its own msgNum=0 was discarded by the gate above; A held
                // it at `sent` forever and B never rendered it. Hold instead; the confirm (peer ack
                // or watchdog give-up) resolves it, and a genuine divergence still tears down then,
                // one confirm window later.
                if case .hold = SessionReducer.confirmGateAction(
                    isPending: SessionConfirmationTracker.shared.isPending(contactId),
                    isControlCarrier: message.isEndSession || message.isSessionResetInit,
                    isPeerInit: message.messageNumber == 0,
                    decryptFailed: true
                ) {
                    Log.info("SESSION_STATE[end_session_deferred]: decrypt failed for \(contactId.prefix(8))… while our SESSION_RESET_INIT is unacked — holding, not tearing down", category: "SessionInit")
                    streamOutcome = holdUntilConfirmResolves(message, from: contactId, reason: "dr_fail_pending_confirm")
                    if isNewChat { context.delete(chat) }
                    return
                }
                Log.info("SESSION_STATE[rust_end_session]: DR diverged for \(contactId.prefix(8))… — sending END_SESSION", category: "SessionInit")
                PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "rust_end_session")
                // Give-up: resolve each discarded message's watermark as it goes. Bare `remove`
                // left held messages deferred forever, pinning the device cursor behind messages
                // nothing would ever revisit — invisible while the queue only ever held inits.
                removePendingMessages(for: contactId)
                SessionHealingService.shared.clearQueue(for: contactId, in: context)
                PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                delegate?.messageRouter(self, needsEndSession: contactId)
                if isNewChat { context.delete(chat) }
                return
            case .fetchPublicKeyBundle(let userId):
                Log.info("SESSION_STATE[rust_session_lost]: re-queuing \(message.id.prefix(8))… for \(userId.prefix(8))…", category: "SessionInit")
                pendingQueue.enqueue(message, for: userId)
                delegate?.messageRouter(self, needsPublicKeyBundle: userId, for: message)
                // Re-queued for session re-establishment — hold the cursor until drained/cleared.
                streamOutcome = .deferred
                return
            default:
                break
            }
        }

        // No actionable routing decision. Duplicates no longer reach here — they are answered at
        // the `checkAckInDb` round-trip above; the parenthetical that used to say "e.g. duplicate,
        // cooldown" was what made 6296 healthy drops look like they belonged in this bucket.
        // Include the action types in the log so we can diagnose why Rust returned no
        // routable event without a live debugger (e.g. a msgNum=0 session init arriving
        // while we're already mid-INITIATOR — the most common source of this fallthrough).
        let actionNames = actions.map { action -> String in
            switch action {
            case .messageDecrypted:              return "messageDecrypted"
            case .callSignalDecrypted:           return "callSignalDecrypted"
            case .sessionHealNeeded:             return "sessionHealNeeded"
            case .sendEndSession:                return "sendEndSession"
            case .fetchPublicKeyBundle:          return "fetchPublicKeyBundle"
            case .saveSessionToSecureStore:      return "saveSessionToSecureStore"
            case .notifyNewMessage:              return "notifyNewMessage"
            case .persistMessage:                return "persistMessage"
            case .persistAck:                    return "persistAck"
            case .pruneAckStore:                 return "pruneAckStore"
            case .checkAckInDb:                  return "checkAckInDb"
            default:                             return "unknown(\(action))"
            }
        }.joined(separator: ",")
        // Known control/signal types falling through here was the face of total delivery
        // failure for four days (INFO looked benign). Promote to ERROR + metric so the
        // next sealed-control regression cannot hide.
        if ContentTypeRouting.isKnownControlContentType(message.contentType) {
            Log.error(
                "handleEvent produced no routing decision for CONTROL ct=\(message.contentType) \(message.id.prefix(8))… msgNum=\(message.messageNumber) actions=[\(actionNames)] — NOT acked, no row written",
                category: "MessageRouter"
            )
            PerformanceMetrics.shared.record(
                .noRoutingDecisionControl,
                label: "ct=\(message.contentType)"
            )
        } else {
            // Ordinary message body. This was INFO because the overwhelming majority of arrivals
            // here were answered duplicates — handled above since 2026-08-04, so what is left is
            // the genuinely undecided remainder: QUEUE_FULL / ROUTING_ERROR notifications and
            // suppressed heals. Those mean a message the peer sent is not in the transcript and
            // nothing will put it there, which is precisely what the acceptance criterion
            // ("0 unexplained ERROR") is supposed to catch.
            Log.error(
                "handleEvent produced no routing decision for \(message.id.prefix(8))… msgNum=\(message.messageNumber) actions=[\(actionNames)] — NOT acked, no row written",
                category: "MessageRouter"
            )
            PerformanceMetrics.shared.record(
                .noRoutingDecisionMessage,
                label: actionNames.isEmpty ? "none" : actionNames
            )
        }
        PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "fallthrough")
        if isNewChat { context.delete(chat) }
        return
    }

    // MARK: - Rust Orchestrator Routing (M5)

    /// `isControl` is **not** "this is a control content type" — deriving it that way would be a
    /// bug, and this comment exists because that derivation was once proposed.
    ///
    /// In the core it means exactly one thing: *archive the session now*. It skips ACK dedup (the
    /// synthetic END_SESSION id is unique per invocation, so it always misses the cache) and skips
    /// wire-payload unpacking, then calls `archive_session` (`message_router.rs:136` and `:289`).
    /// SENDER_SYNC and SESSION_RESET_INIT are control *kinds* that must not archive anything, so a
    /// content-type-derived flag would tear down healthy sessions on every sync.
    ///
    /// `false` here is therefore correct: this builder is only ever reached by ordinary carriers.
    /// END_SESSION (21) and SRI (24) early-exit above, and the synthetic archive event that does
    /// want `true` is constructed elsewhere. `assertNotControlCarrier` makes that precondition
    /// checkable instead of assumed.
    func assertNotControlCarrier(_ message: ChatMessage, path: String) {
        guard message.isEndSession || message.isSessionResetInit else { return }
        // Reaching here means a control carrier slipped past its early exit — the sealed remap
        // missing is the way it could happen. The core would then try to unpack the END_SESSION
        // sentinel as a wire payload and the session would never be archived: a desync that heals
        // only by luck. ERROR + metric so it is not a silent wrong answer.
        Log.error(
            "ROUTING[control_reached_wire_path]: ct=\(message.contentType) message \(message.id.prefix(8))… reached \(path) — it should have early-exited; session will NOT be archived",
            category: "MessageRouter"
        )
        PerformanceMetrics.shared.record(
            .controlCarrierReachedWirePath,
            label: "ct=\(message.contentType)"
        )
    }

    /// Build a typed `CfeIncomingEvent.messageReceived` from a server message.
    private func buildIncomingEvent(message: ChatMessage, otherUserId: String) -> CfeIncomingEvent? {
        assertNotControlCarrier(message, path: "buildIncomingEvent")
        guard !message.rawPayload.isEmpty else {
            Log.error("buildIncomingEvent: empty rawPayload for \(message.id.prefix(8))… — falling back to JSON path", category: "MessageRouter")
            return buildIncomingEventLegacy(message: message, otherUserId: otherUserId)
        }

        return .messageReceived(
            messageId: message.id,
            from: otherUserId,
            data: message.rawPayload,
            msgNum: message.messageNumber,
            kemCt: message.kemCiphertext,
            otpkId: message.kyberOtpkId,
            isControl: false,
            contentType: message.contentType
        )
    }

    /// Legacy JSON path — only used when rawPayload is unavailable (e.g. old healing records).
    private func buildIncomingEventLegacy(message: ChatMessage, otherUserId: String) -> CfeIncomingEvent? {
        assertNotControlCarrier(message, path: "buildIncomingEventLegacy")
        let sealedBox = MessagePadding.unpadCiphertext(message.content)
        guard sealedBox.count >= 12 else {
            Log.error("buildIncomingEventLegacy: sealed box too short (\(sealedBox.count)b) for \(message.id.prefix(8))…", category: "MessageRouter")
            return nil
        }

        let nonce      = Array(sealedBox.prefix(12))
        let ciphertext = Array(sealedBox.dropFirst(12))
        let dhPublicKey = Array(message.ephemeralPublicKey)

        let wireMessage: [String: Any] = [
            "dh_public_key": dhPublicKey.map { Int($0) },
            "message_number": Int(message.messageNumber),
            "ciphertext": ciphertext.map { Int($0) },
            "nonce": nonce.map { Int($0) },
            "previous_chain_length": 0,
            "suite_id": Int(message.suiteId)
        ]

        let wireJsonData: Data
        do {
            wireJsonData = try JSONSerialization.data(withJSONObject: wireMessage)
        } catch {
            Log.error("buildIncomingEventLegacy: failed to encode wire JSON for \(message.id.prefix(8))…: \(error)", category: "MessageRouter")
            return nil
        }

        return .messageReceived(
            messageId: message.id,
            from: otherUserId,
            data: wireJsonData,
            msgNum: message.messageNumber,
            kemCt: message.kemCiphertext,
            otpkId: message.kyberOtpkId,
            isControl: false,
            contentType: message.contentType
        )
    }

    /// Execute typed actions returned by `OrchestratorCore.handleEvent`.
    /// Mix the post-quantum contribution the core asked us to decapsulate into the ratchet.
    ///
    /// Ordering is the whole content of this function:
    ///
    /// * **After the decrypt.** The sender encrypts msg0 against classic-only ratchet state and
    ///   applies its own contribution immediately afterwards — "both sides must apply PQ at the
    ///   same moment" (construct-core `RustPqContributions`). Applying before we decrypt the
    ///   carrier, or on a message the core chose to drop, would drive the root keys apart
    ///   instead of together, which surfaces as a DR divergence on the peer's *next* message.
    /// * **After `executeRustActions`.** That is where `saveSessionToSecureStore` lands, carrying
    ///   session bytes the core exported at decrypt time — i.e. before this mix. Persisting here
    ///   first would simply be overwritten by those staler bytes.
    ///
    /// A no-op unless the core emitted `applyPqContribution`, which it does for every incoming
    /// X3DH carrier (non-empty KEM ciphertext). The RESPONDER's own session-init path
    /// decapsulates directly and never reaches here.
    private func applyIncomingPqContribution(
        _ kemCiphertext: Data?,
        for message: ChatMessage,
        contactId: String
    ) {
        guard let kemCiphertext, !kemCiphertext.isEmpty else { return }
        do {
            try PQCKeyManager.shared.applyIncomingContribution(
                kemCiphertext: kemCiphertext,
                kyberOtpkId: message.kyberOtpkId,
                contactId: contactId
            )
            CryptoManager.shared.saveSessionToKeychain(for: contactId)
        } catch {
            // Downgrade rather than tear down: the classic ratchet is intact and the peer stays
            // reachable. The flag is what stops us claiming a PQ guarantee we do not hold.
            Log.error(
                "PQC: incoming contribution FAILED for \(contactId.prefix(8))…: \(error) — session continues classic-only",
                category: "MessageRouter"
            )
            KeychainManager.shared.savePQXDHDowngradeFlag(for: contactId)
        }
    }

    /// What `executeRustActions` did with the decrypted body — feeds stream-cursor disposition.
    private enum DecryptBodyDisposition {
        /// Fully handled (or terminal drop) for this envelope.
        case terminal
        /// Multi-chunk reassembly still waiting — hold stream cursor; do not pretend durable.
        case incompleteReassembly
    }

    @discardableResult
    private func executeRustActions(
        _ actions: [CfeAction],
        for message: ChatMessage,
        chat: Chat,
        otherUserId: String,
        in context: NSManagedObjectContext
    ) -> DecryptBodyDisposition {
        // Hand off all stateless actions (storage, ACK, timers, heartbeat, call dispatch, etc.)
        // to the centralised executor. Its switch is exhaustive — a new Rust action will
        // refuse to compile until SessionActionExecutor handles it.
        SessionActionExecutor.shared.execute(actions)

        var disposition: DecryptBodyDisposition = .terminal

        // Router-state-bound actions: only .messageDecrypted needs chunkReassembler,
        // chat, message, context, and delegate. Handled inline.
        for action in actions {
            if case .messageDecrypted(let contactId, _, let plaintext) = action {
                let resolvedSender = contactId.isEmpty ? otherUserId : contactId
                checkUsernameUpdate(for: otherUserId, chat: chat, in: context)

                // Client-side block enforcement (decrypt-but-suppress). The ratchet has
                // already advanced (handleOrchestratorEvent + SessionActionExecutor above),
                // so unblocking later resumes the session seamlessly. For a blocked sender we
                // suppress the transcript, the notification, AND the E2E delivery receipt — a
                // receipt would leak delivered/read status to the blocked peer and spend a
                // Privacy Pass token. Server-side block is bypassed under sealed sender, so this
                // client drop is the load-bearing block. The server stream cursor still advances
                // (.durable) + markProcessed dedups, so the queue drains and there is no redelivery.
                // See decisions/sealed-sender-authenticated-transitional.md.
                if BlockedContacts.isBlocked(resolvedSender, in: context) {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    Log.info("SECURITY[block_drop]: suppressed message \(message.id.prefix(8))… from blocked \(resolvedSender.prefix(8))… (ratchet advanced; no store/notify/receipt)", category: "MessageRouter")
                    continue
                }

                // ── The type comes out of the plaintext, not off the wire ────────────────
                // Call signal (12), delivery receipt (14) and ping/ready (25/26) carry their
                // type in KNST byte 5, inside the ciphertext. Nothing outside this decrypt
                // knows what they are: `SealedInner.content_type` is UNSPECIFIED for all four,
                // which is the point — the server can no longer tell a receipt from a body, or
                // see that a call is being set up.
                //
                // `message.contentType` remains meaningful only for the two types that must be
                // recognised *before* decryption (END_SESSION 21, SESSION_RESET_INIT 24) and for
                // the never-sealed carriers (heartbeat 13, SENDER_SYNC 23) — none of which reach
                // this branch framed. See decisions/sealed-content-type-inside-the-plaintext-frame.md.
                if handleFramedSideChannel(
                    plaintext, messageId: message.id, from: otherUserId,
                    resolvedSender: resolvedSender, in: context
                ) {
                    continue
                }
                // Session control (25/26) is dispatched here rather than in the shared helper:
                // on this path a ping/ready only unblocks the outgoing queue, while on the
                // session-init path it also cancels watchdogs. RESET_INIT (24) is deliberately
                // absent — it carries a real X3DH first-ratchet payload and is handled earlier.
                if let control = ChunkedMessageCodec.controlFrame(plaintext),
                   control.contentType == 25 || control.contentType == 26,
                   let op = SessionControlCodec.op(forContentType: Int(control.contentType)) {
                    handleSessionControlSignal(op, for: message, from: otherUserId, chat: chat, in: context)
                    continue
                }
                if let control = ChunkedMessageCodec.controlFrame(plaintext),
                   control.contentType != 0, control.contentType != 1 {
                    // A peer speaking a dialect we do not have. Fall through to the body pipeline
                    // rather than dropping it silently.
                    Log.info("Unknown framed content type \(control.contentType) from \(otherUserId.prefix(8))… — treating as a message body", category: "MessageRouter")
                }

                // Profile share: support binary wire (no JSON) + legacy. Detect on raw Data here.
                if let profile = ProfileShareData.fromBinaryData(plaintext) {
                    ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId, in: context)
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                } else if let str = String(data: plaintext, encoding: .utf8),
                          let profile = ProfileSharingManager.shared.parseProfileMessage(str) {
                    ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId, in: context)
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                }

                switch chunkReassembler.process(data: plaintext, envelopeId: message.id) {
                case .assembled(let text, let quoted, let e2eMessageId, let mediaAlbum, let storagePayload):
                    handleResolvedMessage(
                        text,
                        quotedMessage: quoted,
                        mediaAlbum: mediaAlbum,
                        storagePayload: storagePayload,
                        e2eMessageId: e2eMessageId,
                        for: message,
                        from: otherUserId,
                        chat: chat,
                        in: context
                    )
                case .legacy(let text):
                    handleResolvedMessage(
                        text,
                        quotedMessage: nil,
                        mediaAlbum: nil,
                        e2eMessageId: nil,
                        for: message,
                        from: otherUserId,
                        chat: chat,
                        in: context
                    )
                case .profile(let profileData):
                    // Chunked binary profile share (large profiles with avatars arrive here, not via
                    // the pre-reassembler check above). Render as a profile, never as text.
                    if let profile = ProfileShareData.fromBinaryData(profileData) {
                        ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId, in: context)
                    }
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                case .edit(let targetMessageID, let newText, _):
                    // Modern edit from MessageContent.edit (newText carries caption for media too).
                    // Scoped to the author: a peer may only edit messages it sent us.
                    let fetch = Message.fetchRequest()
                    fetch.predicate = NSPredicate(format: "id ==[c] %@ AND fromUserId == %@", targetMessageID, otherUserId)
                    fetch.fetchLimit = 1
                    if let original = try? context.fetch(fetch).first {
                        let captionOrText = newText.text
                        if !captionOrText.isEmpty {
                            let stored = MessageDisplayCache.shared.payloadData(for: original)
                            if let edited = MediaWireCodec.editedCaptionPayload(storedPlaintext: stored, newCaption: captionOrText) {
                                original.applyStoredEncryption(plaintextData: edited.storagePayload, contactId: otherUserId)
                            } else {
                                original.applyStoredEncryption(plaintext: captionOrText, contactId: otherUserId)
                            }
                        }
                        // Future: if newMedia populated, convert via MediaWireCodec + album wrapper here.
                        original.isEdited = true
                        original.editedAt = Date()
                        Log.info("Applied modern edit to \(targetMessageID.prefix(8))… from \(otherUserId.prefix(8))…", category: "MessageRouter")
                    } else {
                        Log.error("Modern edit target not found: \(targetMessageID.prefix(8))… from \(otherUserId.prefix(8))… — edit dropped", category: "MessageRouter")
                    }
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                case .incomplete:
                    // Every chunk but the last lands here — the normal state of a large message,
                    // not a failure. The alarm for a genuine loss lives where the loss is
                    // (`PendingReassemblyStore.sweepExpired`), so this is DEBUG.
                    //
                    // The L2 mark is the point of this branch. Its bytes are on disk before
                    // `process` returned, so this envelope is genuinely handled and must be
                    // recorded as such. Leaving intermediate envelopes unmarked is what let the
                    // same ids come back through redelivery over and over — the client re-ran the
                    // whole path, the core answered "duplicate" with an empty action list, and the
                    // fallthrough below claimed "ACKing as delivered" while ACKing nothing.
                    //
                    // Safe only because the store is durable: marking an envelope processed while
                    // its bytes lived in process memory would have turned a redelivery storm into
                    // permanent loss on the next restart, which is why this could not be done as
                    // the "quick anti-loop fix" ahead of the store.
                    Log.debug(
                        "Chunk \(message.id.prefix(8))… from \(otherUserId.prefix(8))… — stored, awaiting more",
                        category: "MessageRouter"
                    )
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    disposition = .incompleteReassembly
                case .invalid(let reason):
                    Log.error("Invalid chunked message: \(reason)", category: "MessageRouter")
                    PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "invalid_chunk")
                }
            }
        }
        return disposition
    }


    /// React to a session-handshake control signal (ping/ready) on an established session,
    /// whether it arrived typed (content_type 25/26) or as a legacy plaintext magic string.
    /// Never persists a Message row — these are for the protocol, not the transcript.
    private func handleSessionControlSignal(
        _ op: Shared_Proto_Messaging_V1_SessionOp,
        for message: ChatMessage,
        from otherUserId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)

        switch op {
        case .ready:
            Log.info("SESSION_STATE[session_ready_received]: RESPONDER \(otherUserId.prefix(8))… confirmed session — discarding control signal", category: "MessageRouter")
            releaseConfirmGate(for: otherUserId, chat: chat, in: context)
        default: // .ping (and any other non-ready signal routed here)
            Log.info("SESSION_STATE[session_ping_received]: discarding session ping from \(otherUserId.prefix(8))…", category: "MessageRouter")
            // A ping means the peer initiated and a RESPONDER session is established on our side,
            // so stop buffering outgoing messages that were waiting for a session_ready.
            releaseConfirmGate(for: otherUserId, chat: chat, in: context)
        }
    }

    /// Drop the tie-break confirm gate and flush **both** directions it was holding. Mirror of
    /// `SessionCoordinator.releaseConfirmGate` — the two classes both release the gate, and a
    /// release that flushes only one side is what made an incoming hold impossible before.
    private func releaseConfirmGate(
        for userId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        SessionConfirmationTracker.shared.markConfirmed(userId)
        if let myId = AuthSessionManager.shared.currentUserId {
            MessageRetryManager.shared.sendQueuedMessages(
                for: chat, recipientId: userId, currentUserId: myId, context: context
            )
        }
        replayHeldMessages(for: userId, in: context)
    }

    private func handleResolvedMessage(
        _ decryptedContent: String,
        quotedMessage: Shared_Proto_Messaging_V1_QuotedMessage?,
        mediaAlbum: Shared_Proto_Messaging_V1_MediaAlbumMessage?,
        storagePayload: Data? = nil,
        e2eMessageId: String?,
        for message: ChatMessage,
        from otherUserId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        // HEARTBEAT (content_type=13): silent liveness probe — discard.
        // No receipt: a heartbeat has no row on the sender's side, so a receipt could never
        // move anything. (The old comment claimed the peer "treats a heartbeat as answered
        // when the receipt comes back" — nothing on the sending side reads it; stream liveness
        // is tracked by `lastHeartbeatDate` off the stream-level heartbeatAck, a different
        // mechanism entirely.)
        if message.contentType == 13 {
            Log.debug("Heartbeat received from \(otherUserId.prefix(8))… — session healthy", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            return
        }

        // The magic-string control sniffers that stood here were removed on 2026-08-03. A control
        // signal is identified by KNST byte 5 in executeRustActions and never reaches this
        // function, so matching on decrypted text was a second, silent way to answer the same
        // question. Anything that arrives here is user content.

        // 4. Check for special message types (profile sharing, etc.)
        if let specialMessageHandled = handleSpecialMessage(
            decryptedContent,
            from: otherUserId,
            in: context
        ), specialMessageHandled {
            do {
                try PersistentACKStore.shared.markProcessedOrThrow(message.id, senderId: otherUserId, in: context)
            } catch {
                Log.error("Failed to persist ACK for special message \(message.id.prefix(8))…: \(error)", category: "MessageRouter")
            }
            return  // Special message handled, don't save as regular message
        }

        // Legacy envelope-level edits (envelope.edits_message_id) are gone: the field is
        // reserved server-side and edits now travel inside the encrypted payload as
        // MessageContent.edit (handled in handleResolvedMessage's `.edit` case). No
        // top-level edit branch here anymore.

        // Canonical row id: the sender's E2E id from the encrypted KNST header when present,
        // else the envelope id. The server reassigns envelope ids on the sealed-sender path,
        // so only the E2E id lets the sender's cross-device references (edits, receipts,
        // reply targets) resolve on our side. Transport-level ACKs stay on the envelope id.
        let canonicalId: String
        do {
            canonicalId = try saveMessage(for: chat, with: message, decryptedContent: decryptedContent,
                                          quotedMessage: quotedMessage, mediaAlbum: mediaAlbum,
                                          storagePayload: storagePayload,
                                          e2eMessageId: e2eMessageId, in: context)
            if let mediaAlbum {
                MediaWireCodec.storeThumbnails(from: mediaAlbum, for: canonicalId)
            }
            try PersistentACKStore.shared.markProcessedOrThrow(message.id, senderId: otherUserId, in: context)
        } catch {
            Log.error("Failed to persist message \(message.id.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        // 6. The message is in the transcript — tell the sender, so their checkmark is true.
        // Carries the canonical (E2E) id so the sender can match its own local row: the envelope
        // id is server-reassigned on the sealed path and means nothing to the sender.
        OutboundSessionService.sendDeliveryReceipt(for: [canonicalId], to: otherUserId, in: context)

        SessionActivityTracker.shared.recordActivity(for: message.from)
        Log.info("Message received and saved: \(message.id)", category: "MessageRouter")
    }
    
    // MARK: - Chat Management
    
    /// Find or create chat for user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: Tuple of (chat, isNewChat)
    private func findOrCreateChat(
        for userId: String,
        in context: NSManagedObjectContext
    ) throws -> (Chat, Bool) {
        do {
            guard let result = try Chat.findOrCreate(
                forUserId: userId,
                in: context,
                missingUserPolicy: .createContact
            ) else {
                // createContact never returns nil — defensive
                throw NSError(
                    domain: "MessageRouter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "findOrCreateChat returned nil for \(userId)"]
                )
            }
            return (result.chat, result.created)
        } catch {
            Log.error("Failed to findOrCreate chat for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
            throw error
        }
    }
    
    // MARK: - First Message Handling
    
    /// Handle first message from user (no session yet)
    /// Returns the stream-cursor disposition for the message: `.deferred` when it is queued
    /// (or already queued / dropped at the cap) and must hold the resume cursor until drained,
    /// `.durable` when it is a give-up that the cursor may advance past.
    @discardableResult
    private func handleFirstMessage(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        isNewChat: Bool,
        in context: NSManagedObjectContext,
        forceReinit: Bool = false
    ) -> StreamCursorTracker.Outcome {
        // Dedup redelivered handshakes: a msg0 that already completed session init once
        // (receipt raced the server's stream cursor on reconnect) must never re-init —
        // its X3DH OTPK was consumed by the first init, so a re-init can only fail with
        // "OTPK not found" and spuriously kick off the 3-DH heal cycle. Re-ACK and move on.
        //
        // `forceReinit` bypasses this: SESSION_RESET_INIT just archived the live session,
        // so there is genuinely no session now. Skipping re-init because the reset-init's
        // id was seen (and marked processed) in an earlier *failed* attempt would leave the
        // peer permanently sessionless — the deadlock that spams "session out of sync".
        // A reset-init must always rebuild, even for a previously-seen id.
        if !forceReinit && PersistentACKStore.shared.isProcessed(message.id, in: context) {
            Log.info("SESSION_STATE[first_message_dedup]: \(message.id.prefix(8))… from \(userId.prefix(8))… already processed — re-ACKing, skipping re-init", category: "SessionInit")
            // Truthful: the first init decrypted and saved this msg0. Same reasoning as the
            // ACK-store dedup above — the re-send is the sender's only remaining checkmark.
            OutboundSessionService.sendDeliveryReceipt(for: [message.id], to: userId, in: context)
            if isNewChat { context.delete(chat) }
            return .durable
        }

        // Queue disposition comes from the pure SessionReducer, fed by the authoritative facts
        // we hold here: no Rust session exists (this method is only reached when !hasSession),
        // and whether init is already underway (something already queued for this peer).
        // `.startInit` ⇒ this is the first message → fetch the bundle; otherwise just queue.
        let disposition = SessionReducer.incomingDisposition(
            hasActiveSession: false,
            isInitInFlight: pendingQueue.count(for: userId) > 0
        )
        let isFirstForUser = disposition.contains(.startInit)

        // Deduplicate: skip if same message ID is already in the queue
        if pendingQueue.contains(messageId: message.id, for: userId) {
            Log.debug("Skipping duplicate queued message \(message.id.prefix(8))...", category: "MessageRouter")
            // Do NOT ACK as delivered yet: session init may still fail, and acknowledging would
            // cause the server to drop the pending message even though we haven't decrypted it.
            return .deferred
        }

        // Guard: initReceivingSession requires messageNumber=0 (X3DH handshake).
        // If we have no session and the message is already mid-ratchet, we can never
        // initialize from it — request the sender to restart their session instead.
        if message.messageNumber > 0 && isFirstForUser {
            Log.info("No session for \(userId.prefix(8)) but messageNumber=\(message.messageNumber) — requesting END_SESSION so sender restarts", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "mid_ratchet_no_session")
            pendingQueue.touch(userId)
            // Throttle the user-visible notice + restart request per contact: a burst of
            // mid-ratchet messages would otherwise stack identical "out of sync" bubbles and
            // re-ask the sender to restart on every one. Cursor/ACK bookkeeping above is
            // per-message and unaffected; only the notice + END_SESSION are rate-limited.
            if shouldEmitOutOfSyncNotice(for: userId) {
                // Says what is true, not what we intend. The old text — "Asking contact to
                // restart…" — promised an action this code cannot confirm: `needsEndSession` is
                // fire-and-forget into a Task, and `SessionCoordinator` gates it behind its own
                // cooldown. Observed on device 2026-08-03: the bubble appeared and the very next
                // line was `END_SESSION cooldown active …, skipping`. Two timers that are supposed
                // to agree by hand had drifted, and the user was told about a request that was
                // never made.
                //
                // The state is certain, so that is what the bubble states; recovery is still
                // attempted below, rate-limited, and either this call sends END_SESSION or a very
                // recent one already did.
                addSystemMessage(
                    NSLocalizedString("system_session_out_of_sync", comment: "Shown in a chat when messages from a contact cannot be read because the encrypted session is out of sync"),
                    toUserId: userId,
                    in: context
                )
                delegate?.messageRouter(self, needsEndSession: userId)
            }
            if isNewChat { context.delete(chat) }
            // Give-up: message is marked processed + sender asked to restart; nothing to drain,
            // so the cursor may advance past it.
            return .durable
        }

        guard pendingQueue.enqueue(message, for: userId) else {
            Log.info("Pending queue saturated for \(userId.prefix(8))… — not queueing until session init completes", category: "MessageRouter")
            // Not enqueued, but DON'T advance: the server keeps re-delivering it; once the queue
            // drains (init completes) a later re-delivery is enqueued and processed. Holding the
            // cursor (rather than dropping) trades a bounded stall for no message loss.
            return .deferred
        }

        Log.info("Message queued for session init from \(userId) — queue size: \(pendingQueue.count(for: userId))", category: "MessageRouter")
        Log.info("SESSION_STATE[first_message]: userId=\(userId.prefix(8))..., messageNumber=\(message.messageNumber), action=\(isFirstForUser ? "fetch_bundle" : "queued")", category: "SessionInit")

        if isNewChat {
            do {
                try context.saveOrThrow(category: "MessageRouter")
                Log.debug("Saved new chat for \(userId)", category: "MessageRouter")
            } catch {
                Log.error("Failed to save new chat: \(error)", category: "MessageRouter")
            }
        }

        if isFirstForUser {
            delegate?.messageRouter(self, needsPublicKeyBundle: userId, for: message)
        }

        // Queued for session init — hold the resume cursor until this message is drained
        // (re-routed → durable) or the queue is cleared (give-up).
        return .deferred
    }

    // MARK: - Session Message Handling
    
    // MARK: - Rust Heal Decision

    /// Dispatch a `SessionHealNeeded` action returned by the Rust orchestrator.
    ///
    /// - `role == "Initiator"` (WE WIN): our session is intact (Rust DR rollback). ACK peer's
    ///   X3DH init and send END_SESSION + ping so they become RESPONDER.
    /// - `role == "Responder"` (WE LOSE): archive our desynchronised session so the peer (INITIATOR)
    ///   can establish a fresh one, then trigger the RESPONDER heal path.
    private func handleRustHealDecision(
        role: String,
        contactId: String,
        message: ChatMessage,
        in context: NSManagedObjectContext
    ) {
        let myUserId = AuthSessionManager.shared.currentUserId ?? ""
        let suiteId = Int(KeychainManager.shared.loadSessionSuiteId(userId: contactId) ?? 0)

        if role == "Initiator" {
            // We are INITIATOR (higher userId — see SessionReducer.tieBreakRole) — WE WIN the tie-break.
            // The Rust session is already intact thanks to the DR snapshot/rollback.
            Log.info("SESSION_STATE[tie_break_win]: kept INITIATOR (my=\(myUserId.prefix(8))… > peer=\(contactId.prefix(8))…), suiteId=\(suiteId)", category: "SessionInit")
            PersistentACKStore.shared.markProcessed(message.id, senderId: contactId, in: context)
            PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "tie_break_win")
            delegate?.messageRouter(self, didWinTieBreak: contactId)
        } else {
            // We are RESPONDER (lower deviceId) — peer WINS. Archive our session and heal.
            guard SessionHealingService.shared.canHeal(message) else {
                Log.error("SESSION_STATE[heal_limit_exceeded]: too many heal attempts for \(contactId.prefix(8))… — sending END_SESSION", category: "SessionInit")
                PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "heal_limit_exceeded")
                delegate?.messageRouter(self, needsEndSession: contactId)
                return
            }
            Log.info("SESSION_STATE[heal_triggered]: becoming RESPONDER (my=\(myUserId.prefix(8))… < peer=\(contactId.prefix(8))…), suiteId=\(suiteId)", category: "SessionInit")
            CryptoManager.shared.archiveSession(for: contactId, reason: .manualReset)
            SessionHealingService.shared.enqueue(message, in: context)
            pendingQueue.enqueue(message, for: contactId)
            delegate?.messageRouter(self, needsSessionHeal: contactId, failedMessage: message)
        }
    }

    /// Check if username needs updating
    private func checkUsernameUpdate(
        for userId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        guard let user = chat.otherUser else { return }
        
        let usernameIsGuid = user.username == user.id || user.username == userId
        let displayNameIsGuid = user.displayName == user.id || user.displayName == userId
        
        if usernameIsGuid || displayNameIsGuid {
            Log.info("Username for \(userId) is still UUID, requesting update", category: "MessageRouter")
            delegate?.messageRouter(self, needsUsernameUpdate: userId)
        }
    }
    
    // MARK: - Special Message Types

    private func parseJSONObject(
        _ data: Data,
        category: String,
        context: String
    ) throws -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Log.error("\(context): JSON parse failed: \(error)", category: category)
            throw error
        }
    }

    // MARK: - E2E Delivery Receipts

    /// Parse and dispatch an incoming E2E delivery receipt (content_type=14).
    ///
    /// Payload is binary proto `Shared_Proto_Signaling_V1_DeliveryReceipt` with
    /// `.direct(DirectReceipt{ messageIds, ... })`. The legacy JSON payload
    /// (`{"type":"delivery_receipt",…}`) was retired once all clients emitted proto
    /// (producer flipped 2026-06-11); a stale JSON payload now fails proto parse and is
    /// discarded — never rendered, since ct=14 is intercepted before the chunk reassembler
    /// and `Message.isServiceArtifact` guards any leak.
    private func handleIncomingE2EDeliveryReceipt(
        _ payload: Data,
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        // No receipt for a receipt: ct=14 has no row on the sender's side, and answering one
        // receipt with another is the shape of a loop.
        defer {
            PersistentACKStore.shared.markProcessed(messageId, senderId: otherUserId, in: context)
        }

        guard !payload.isEmpty else {
            Log.error("E2E receipt: empty payload from \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }

        let ids = parseBinaryReceipt(payload, from: otherUserId) ?? []

        guard !ids.isEmpty else {
            Log.error("E2E receipt: failed to parse payload from \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }

        Log.info("E2E receipt: \(ids.count) message(s) confirmed by \(otherUserId.prefix(8))…", category: "MessageRouter")
        delegate?.messageRouter(self, didDecryptDeliveryReceipt: ids)
    }

    /// Parse binary proto delivery receipt: `Shared_Proto_Signaling_V1_DeliveryReceipt`
    private func parseBinaryReceipt(_ payload: Data, from otherUserId: String) -> [String]? {
        do {
            let receipt = try Shared_Proto_Signaling_V1_DeliveryReceipt(serializedBytes: payload)
            switch receipt.receiptType {
            case .direct(let direct):
                guard !direct.messageIds.isEmpty else {
                    Log.error("E2E receipt: empty messageIds in binary proto from \(otherUserId.prefix(8))…", category: "MessageRouter")
                    return nil
                }
                return direct.messageIds
            case .group:
                Log.info("E2E receipt: group receipt received (not yet supported) from \(otherUserId.prefix(8))…", category: "MessageRouter")
                return nil
            case nil:
                Log.error("E2E receipt: no receiptType in binary proto from \(otherUserId.prefix(8))…", category: "MessageRouter")
                return nil
            }
        } catch {
            Log.error("E2E receipt: binary proto parse failed from \(otherUserId.prefix(8))…: \(error)", category: "MessageRouter")
            return nil
        }
    }

    /// Handle special message types (profile, etc.)
    /// - Returns: true if special message was handled
    private func handleSpecialMessage(
        _ decryptedContent: String,
        from userId: String,
        in context: NSManagedObjectContext
    ) -> Bool? {
        // Check for profile message
        if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let jsonData = decryptedContent.data(using: .utf8) {
            let jsonDict: [String: Any]
            do {
                guard let parsed = try parseJSONObject(jsonData, category: "MessageRouter", context: "special message") else {
                    return false
                }
                jsonDict = parsed
            } catch {
                return false
            }
            guard let type = jsonDict["type"] as? String else {
                return false
            }

            if type == "profile" {
                if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) ??
                                     (decryptedContent.data(using: .utf8).flatMap { ProfileSharingManager.shared.parseProfileMessage(from: $0) }) {
                    Log.info("Received profile message from \(userId)", category: "MessageRouter")
                    ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId, in: context)
                    return true
                } else {
                    Log.info("Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                    return true
                }
            }
        }

        return false
    }

    // MARK: - END_SESSION Handling

    /// Handle SESSION_RESET_INIT — atomic archive of old session + RESPONDER init in a single pass.
    ///
    /// Replaces the two-step `END_SESSION` → 200 ms delay → `msgNum=0` sequence used in the
    /// tie-break WIN path. The INITIATOR sends one message with `CONTENT_TYPE_SESSION_RESET_INIT=24`
    /// whose payload is the X3DH init (`msgNum=0`). RESPONDER:
    /// 1. Archives the old session (same as `handleEndSession`)
    /// 2. Routes the X3DH payload through `handleFirstMessage` (normal RESPONDER init)
    private func handleSessionResetInit(
        message: ChatMessage,
        from userId: String,
        in context: NSManagedObjectContext
    ) {
        // 1. Archive old session via Rust orchestrator (canonical path); Swift fallback otherwise.
        var rustHandled = false
        if CryptoManager.shared.orchestratorCore != nil {
            let endSessionData = Data("__END_SESSION__".utf8)
            let event = CfeIncomingEvent.messageReceived(
                messageId: "sri_archive_\(userId)_\(Int(Date().timeIntervalSince1970))",
                from: userId,
                data: endSessionData,
                msgNum: 0,
                kemCt: Data(),
                otpkId: 0,
                isControl: true,
                contentType: 0
            )
            do {
                let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "sri_archive")
                OutboundSessionService.shared.executeStorageActions(actions)
                rustHandled = true
            } catch {
                Log.error("SESSION_RESET_INIT: Rust archive failed for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
            }
        }
        if !rustHandled {
            CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
        }

        // 2. Re-queue outgoing messages sent under the old session (cannot be decrypted by peer).
        requeueUndeliveredOutgoing(for: userId, in: context)

        // 3. Remove stale pending messages and clear heal queue.
        pendingQueue.remove(for: userId)
        SessionHealingService.shared.clearQueue(for: userId, in: context)

        // 4. Route the X3DH payload as a fresh msgNum=0 — triggers normal RESPONDER init path.
        //    forceReinit: the session was just archived above, so the isProcessed dedup in
        //    handleFirstMessage must not short-circuit re-init even if this reset-init id was
        //    seen (and marked processed) in a prior failed attempt — otherwise the peer stays
        //    sessionless forever and we spam "session out of sync".
        do {
            let (chat, isNewChat) = try findOrCreateChat(for: userId, in: context)
            handleFirstMessage(message, from: userId, chat: chat, isNewChat: isNewChat, in: context, forceReinit: true)

            Log.info("SESSION_RESET_INIT: old session archived, RESPONDER init triggered for \(userId.prefix(8))…", category: "MessageRouter")
        } catch {
            Log.error("SESSION_RESET_INIT: failed to resolve chat for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
        }
    }

    /// Handle END_SESSION message.
    ///
    /// Primary path: delegate archiving to Rust via `handleEventJson` so the
    /// archive format is canonical and owned by the Rust orchestrator.
    /// Fallback: if the Rust path fails (e.g., no active session), use the
    /// existing Swift `archiveSession` to preserve existing behaviour.
    private func handleEndSession(from userId: String, messageTimestamp: UInt64, in context: NSManagedObjectContext) {
        // Guard against stale END_SESSION messages: if the message's server timestamp
        // predates our current active session, it was queued from a previous session
        // cycle and re-delivered by the server. ACK it (already done) and stop here —
        // tearing down a healthy session based on a stale END_SESSION causes cascades.
        if delegate?.messageRouter(self, isEndSessionStale: userId, timestamp: messageTimestamp) == true {
            Log.info("Discarding stale END_SESSION from \(userId.prefix(8))… (ts=\(messageTimestamp))", category: "MessageRouter")
            return
        }

        Log.info("Handling END_SESSION from \(userId)", category: "MessageRouter")

        // 1. Archive the session — prefer Rust-owned archiving.
        var rustHandled = false
        if CryptoManager.shared.orchestratorCore != nil {
            let endSessionData = Data("__END_SESSION__".utf8)
            let event = CfeIncomingEvent.messageReceived(
                messageId: "end_session_\(userId)_\(Int(Date().timeIntervalSince1970))",
                from: userId,
                data: endSessionData,
                msgNum: 0,
                kemCt: Data(),
                otpkId: 0,
                isControl: true,
                contentType: 0
            )
            do {
                let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "end_session_archive")
                OutboundSessionService.shared.executeStorageActions(actions)
                rustHandled = true
                Log.debug("END_SESSION: session archived via Rust orchestrator for \(userId.prefix(8))…", category: "MessageRouter")
            } catch {
                Log.error("END_SESSION: Rust archive failed for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
                Log.debug("END_SESSION: Rust handleEvent failed for \(userId.prefix(8))… — falling back to Swift archive", category: "MessageRouter")
            }
        }

        if !rustHandled {
            CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
            Log.debug("END_SESSION: session archived via Swift fallback for \(userId.prefix(8))…", category: "MessageRouter")
        }

        // Defence-in-depth: guarantee Keychain is clear even if the Rust path
        // did not reach archive_session() (e.g. export failure returning vec![]).
        // The normal path now emits CfeAction.sessionTerminated which already clears
        // Keychain via acceptSessionTerminated(), so this is a no-op in the happy path.
        KeychainManager.shared.deleteSession(for: userId)
        KeychainManager.shared.deleteSessionSuiteId(userId: userId)
        Log.debug("END_SESSION: Keychain hot session cleared for \(userId.prefix(8))… (post-archive)", category: "MessageRouter")

        // 2. Re-queue any outgoing messages that were sent to the server but not yet
        //    delivered (no ACK). These were encrypted with the now-archived session keys
        //    and cannot be decrypted by the peer under the new session — so they must be
        //    re-encrypted and re-sent once the new session is established.
        requeueUndeliveredOutgoing(for: userId, in: context)

        // 3. Remove any pending *incoming* messages and healing queue for this user
        pendingQueue.remove(for: userId)
        SessionHealingService.shared.clearQueue(for: userId, in: context)

        // 4. Notify coordinator so the natural INITIATOR can prewarm immediately.
        delegate?.messageRouter(self, receivedEndSession: userId, timestamp: messageTimestamp)

        Log.info("END_SESSION handled for \(userId)", category: "MessageRouter")
    }
    
    /// Marks outgoing messages that were sent to the server but never delivered as `.queued`,
    /// so they can be re-encrypted and re-sent under the fresh session after END_SESSION.
    /// All `.sent` messages for the contact are considered — the time window is not capped,
    /// because the user may have been offline longer than any fixed window.
    /// Messages that have already been re-queued `maxMessageRetryAttempts` times are permanently
    /// marked as `.failed` to break infinite session-reset amplification cycles.
    private func requeueUndeliveredOutgoing(
        for userId: String,
        in context: NSManagedObjectContext
    ) {
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)

        let chat: Chat
        do {
            guard let fetchedChat = try context.fetch(chatFetch).first else { return }
            chat = fetchedChat
        } catch {
            Log.error("END_SESSION: failed to fetch chat for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        let msgFetch = Message.fetchRequest()
        msgFetch.predicate = NSPredicate(
            format: "chat == %@ AND isSentByMe == YES AND deliveryStatusRaw == %d",
            chat,
            DeliveryStatus.sent.rawValue
        )
        msgFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        let messages: [Message]
        do {
            messages = try context.fetch(msgFetch)
        } catch {
            Log.error("END_SESSION: failed to fetch sent messages for \(userId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }
        guard !messages.isEmpty else { return }

        let maxRetries = FeatureFlags.maxMessageRetryAttempts
        var requeuedCount = 0
        var droppedCount = 0

        var serverAcceptedCount = 0
        for msg in messages {
            let msgId = msg.id
            guard !msgId.isEmpty else { continue }

            // Wire payload is removed immediately after the server accepts the message
            // (status="sent"/"delivered"). If the payload is gone, the server already has
            // the ciphertext — re-queuing would cause retryMessage to fail instantly with
            // "payload_expired", permanently marking the message failed even though it was
            // accepted. Leave it as .sent; a delivery receipt may still arrive later.
            if OutgoingWirePayloadStore.shared.loadChunks(baseMessageId: msgId) == nil {
                serverAcceptedCount += 1
                // Per-message INFO here flooded device logs during END_SESSION storms
                // (dozens of lines per control message). Count is logged once below.
                continue
            }

            if msg.retryCount < maxRetries {
                msg.deliveryStatus = .queued
                requeuedCount += 1
            } else {
                // Message has survived maxRetries session resets without delivery receipt.
                // Mark permanently failed to break re-queue amplification cycle.
                msg.deliveryStatus = .failed
                droppedCount += 1
                Log.error("END_SESSION: dropping re-queue for \(msg.id.prefix(8))… after \(msg.retryCount) attempts — marking failed", category: "MessageRouter")
            }
        }
        if serverAcceptedCount > 0 {
            Log.info("END_SESSION: skipped \(serverAcceptedCount) message(s) for \(userId.prefix(8))… — already accepted by server", category: "MessageRouter")
        }
        context.saveAndLog()

        if requeuedCount > 0 {
            Log.info("END_SESSION: re-queued \(requeuedCount) message(s) for \(userId.prefix(8))… — will resend under new session", category: "MessageRouter")
        }
        if droppedCount > 0 {
            Log.error("END_SESSION: permanently failed \(droppedCount) message(s) for \(userId.prefix(8))… (exceeded retry limit)", category: "MessageRouter")
        }
    }

    /// Add a system message to chat
    private func addSystemMessage(
        _ text: String,
        toUserId userId: String,
        in context: NSManagedObjectContext
    ) {
        guard let currentUserId = AuthSessionManager.shared.currentUserId else { return }
        
        // Find chat
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])

        let chat: Chat
        do {
            guard let fetchedChat = try context.fetch(fetchRequest).first else {
                Log.error("Cannot add system message: chat not found for \(userId)", category: "MessageRouter")
                return
            }
            chat = fetchedChat
        } catch {
            Log.error("Cannot add system message: failed to fetch chat for \(userId): \(error)", category: "MessageRouter")
            return
        }
        
        // Do not restate a condition that has not changed and about which nothing has happened.
        //
        // The 30 s cooldown on the caller bounds how often a *new* notice can appear; it does not
        // stop the same one stacking hours apart, and on device it produced five identical
        // "session out of sync" blocks in a row (2026-08-04, both sides). Five of them say exactly
        // what one says: the session is still broken. A repeat is only informative if something
        // reached the transcript in between — and that is precisely the test here, because a
        // message arriving would put a different row last.
        if Self.isRepeatOfLastRow(text, in: chat, context: context) {
            Log.debug("System notice suppressed — identical to the last row in this chat", category: "MessageRouter")
            return
        }

        let message = Message(context: context)
        message.id = UUID().uuidString
        message.chat = chat
        message.fromUserId = "SYSTEM"
        message.toUserId = currentUserId
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0

        message.applyStoredEncryption(plaintext: text, contactId: userId)
        
        chat.applyPreview(text: text, timestamp: message.timestamp)

        do {
            try context.saveOrThrow(category: "MessageRouter")
            Log.debug("System message added to chat with \(userId)", category: "MessageRouter")
        } catch {
            Log.error("Failed to save system message: \(error)", category: "MessageRouter")
        }
    }

    /// Route a framed payload that is a pure side channel — a call signal (12) or a delivery
    /// receipt (14). Returns true when it was consumed and must never become a chat row.
    ///
    /// Shared by the ordinary path and by `SessionCoordinator`'s session-init path, which had no
    /// equivalent at all: it knew about session-control ops and nothing else, so a receipt arriving
    /// as the first message of a fresh session was persisted and rendered as a bubble containing
    /// the id it referenced (observed 2026-08-04, `08b9653c-…`).
    ///
    /// Deliberately **not** extended to session control (24/25/26). Those look like one decision
    /// and are two: the session-init path additionally cancels tie-break watchdogs, responder
    /// fallbacks and pending re-inits, which the ordinary path has no business doing. Folding them
    /// in here would have silently dropped those cancellations — the same class of loss this whole
    /// exercise is about, just in the other direction.
    ///
    /// An unknown framed type returns false: a peer speaking a newer dialect should reach the body
    /// pipeline rather than vanish.
    func handleFramedSideChannel(
        _ plaintext: Data,
        messageId: String,
        from otherUserId: String,
        resolvedSender: String,
        in context: NSManagedObjectContext
    ) -> Bool {
        guard let control = ChunkedMessageCodec.controlFrame(plaintext) else { return false }

        switch control.contentType {
        case 12:
            if let signal = CallManager.decodeSignalProto(from: control.payload) {
                CallManager.shared.handleCallSignalProto(from: resolvedSender, signal: signal)
            } else {
                Log.error("Call signal frame from \(otherUserId.prefix(8))… failed to decode", category: "MessageRouter")
            }
            PersistentACKStore.shared.markProcessed(messageId, senderId: otherUserId, in: context)
            return true
        case 14:
            handleIncomingE2EDeliveryReceipt(control.payload, messageId: messageId, from: otherUserId, in: context)
            return true
        default:
            return false
        }
    }

    /// True when the newest row in `chat` is a system row carrying exactly `text`.
    ///
    /// Fetches one row, not the transcript — this runs on every notice. Compares the decrypted
    /// text rather than a stored marker so it stays correct if the wording changes: two rows are
    /// duplicates when the user would read them as duplicates.
    private static func isRepeatOfLastRow(
        _ text: String,
        in chat: Chat,
        context: NSManagedObjectContext
    ) -> Bool {
        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "chat == %@", chat)
        fetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetch.fetchLimit = 1
        guard let last = try? context.fetch(fetch).first else { return false }
        return last.fromUserId == "SYSTEM" && last.displayText == text
    }

    #if DEBUG
    /// Test seam for `isRepeatOfLastRow`. The rule is about what the user sees in a transcript,
    /// so it is worth testing directly rather than through the whole routing path.
    static func isRepeatOfLastRowForTesting(
        _ text: String,
        in chat: Chat,
        context: NSManagedObjectContext
    ) -> Bool {
        isRepeatOfLastRow(text, in: chat, context: context)
    }
    #endif

    // MARK: - Message Persistence
    
    /// Save message to Core Data
    /// Persists an incoming message and returns the canonical row id it was stored under.
    /// `e2eMessageId` (sender's id from the encrypted KNST header) wins over the envelope id —
    /// the server reassigns envelope ids on the sealed-sender path, and edits/receipts/replies
    /// reference the sender's id. Falls back to the envelope id if the E2E id already belongs
    /// to a different author's message (collision guard).
    @discardableResult
    private func saveMessage(
        for chat: Chat,
        with messageData: ChatMessage,
        decryptedContent: String,
        quotedMessage: Shared_Proto_Messaging_V1_QuotedMessage?,
        mediaAlbum: Shared_Proto_Messaging_V1_MediaAlbumMessage? = nil,
        storagePayload incomingStorage: Data? = nil,
        e2eMessageId: String? = nil,
        in context: NSManagedObjectContext
    ) throws -> String {
        // Prefer reassembler CTM1 (messageContent / mediaAlbum); fall back to album encode or UTF-8.
        let storagePayload: Data = {
            if let incomingStorage, !incomingStorage.isEmpty {
                return incomingStorage
            }
            if let album = mediaAlbum {
                return LocalMessagePayload.encodeMediaAlbum(album)
            }
            return LocalMessagePayload.encodeText(decryptedContent)
        }()
        let previewSource = LocalMessagePayload.decode(storagePayload).previewHint

        var canonicalId = (e2eMessageId ?? messageData.id).lowercased()
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id ==[c] %@", canonicalId)
        fetchRequest.fetchLimit = 1

        // Check if message already exists (from background fetch, retry redelivery, …)
        if let existingMessage = try context.fetch(fetchRequest).first {
            if existingMessage.fromUserId == messageData.from {
                // Update encrypted content if message wasn't previously decrypted
                if !existingMessage.hasDecryptedContent {
                    Log.debug("Updating decrypted content for message \(canonicalId)", category: "MessageRouter")
                    existingMessage.applyStoredEncryption(plaintextData: storagePayload, contactId: messageData.from)
                    // Force when the preview is blank: a message that was stored undecryptable
                    // left an empty preview behind, and recovering its text must fill that in
                    // even though a newer message has since moved `lastMessageTime` forward.
                    chat.applyPreview(
                        text: previewSource,
                        timestamp: existingMessage.timestamp,
                        force: (chat.lastMessageText ?? "").isEmpty
                    )
                    try context.saveOrThrow(category: "MessageRouter")
                    Log.debug("Updated message decryption", category: "MessageRouter")
                }
                return canonicalId  // Message already exists
            }
            // The E2E id collides with a row from a different author — never overwrite or
            // suppress it; store this message under the (unique) envelope id instead.
            Log.error("E2E id \(canonicalId.prefix(8))… collides with a message from another author — falling back to envelope id", category: "MessageRouter")
            canonicalId = messageData.id.lowercased()
            let envelopeFetch = Message.fetchRequest()
            envelopeFetch.predicate = NSPredicate(format: "id ==[c] %@", canonicalId)
            envelopeFetch.fetchLimit = 1
            if try context.fetch(envelopeFetch).first != nil {
                return canonicalId  // already stored under the envelope id (e.g. by background fetch)
            }
        }

        // Create new message
        let message = Message(context: context)
        message.id = canonicalId
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.contentType = .regular
        message.timestamp = Date.fromRemoteTimestamp(messageData.timestamp)
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        message.applyStoredEncryption(plaintextData: storagePayload, contactId: messageData.from)

        // Restore reply-to context so the receiver sees the same reply bubble as the sender.
        // Priority: QuotedMessage from proto plaintext (privacy-safe, no server visibility).
        // Fallback: legacy replyToMessageId from envelope (old clients without proto payload).
        if let qm = quotedMessage, !qm.messageID.isEmpty {
            message.replyToMessageId = qm.messageID.lowercased()
            message.replyToContent = qm.textPreview.isEmpty ? nil : qm.textPreview
        } else if !messageData.replyToMessageId.isEmpty {
            message.replyToMessageId = messageData.replyToMessageId.lowercased()
            let replyFetch = Message.fetchRequest()
            replyFetch.predicate = NSPredicate(format: "id ==[c] %@", messageData.replyToMessageId)
            replyFetch.fetchLimit = 1
            do {
                if let replyMsg = try context.fetch(replyFetch).first {
                    let replyText = replyMsg.displayText
                    message.replyToContent = replyText.isEmpty ? nil : replyText
                }
            } catch {
                Log.error("Failed to fetch reply context for \(messageData.id.prefix(8))…: \(error)", category: "MessageRouter")
            }
        }

        chat.applyPreview(text: previewSource, timestamp: message.timestamp)
        // Same "can the user actually see this?" test the banner uses — an open chat behind a
        // backgrounded app is not visible, and used to keep unreadCount pinned at 0.
        if !InAppNotificationService.isChatVisible(chat.id) {
            chat.unreadCount += 1
        }

        try context.saveOrThrow(category: "MessageRouter")
        Log.debug(
            "Chat metadata updated chatId=\(chat.id.prefix(8))… preview='\(chat.lastMessageText ?? "")' unread=\(chat.unreadCount) ts=\(chat.lastMessageTime?.description ?? "nil")",
            category: "MessageRouter"
        )
        PerformanceMetrics.shared.messageUIDisplayed(messageId: messageData.id)

        let senderId = messageData.from

        // ── Incoming flood check ────────────────────────────────────────────
        let floodResult = IncomingFloodGuard.shared.check(senderId: senderId)

        // ── Lockdown check ──────────────────────────────────────────────────
        let lockdownSuppressed = LockdownManager.shared.shouldSuppress(senderId: senderId)

        // Decide whether to show notification
        let chatId    = chat.id
        let isMuted   = chat.isMuted
        let senderName = (chat.otherUser?.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
                            .flatMap { $0.isEmpty ? nil : $0 }
                        ?? chat.otherUser?.username
                        ?? "Unknown"
        let preview   = Chat.formatPreviewText(previewSource)

        switch floodResult {
        case .burstDetected(let count):
            // First burst event — post a single special system notification instead
            // of the regular message preview. Subsequent messages are silently dropped
            // from notifications until the user reviews.
            Log.info("Burst detected: \(count) msgs/30s from \(senderId.prefix(8))…", category: "FloodGuard")
            if !isMuted {
                InAppNotificationService.shared.handleFloodAlert(
                    chatId: chatId,
                    senderName: senderName,
                    messageCount: count
                )
            }

        case .alreadySuppressed:
            // Silently save; no notification
            Log.debug("Suppressed notification from flooder \(senderId.prefix(8))…", category: "FloodGuard")

        case .normal:
            if lockdownSuppressed {
                Log.debug("Lockdown: suppressed notification from new sender \(senderId.prefix(8))…", category: "LockdownManager")
            } else if !isMuted {
                InAppNotificationService.shared.handle(
                    chatId: chatId,
                    isMuted: false,
                    senderName: senderName,
                    preview: preview
                )
            }
        }

        return canonicalId
    }

    // MARK: - SENDER_SYNC Handling

    /// Handle an incoming SENDER_SYNC message — a copy of an outgoing message sent by
    /// the user's own other device. Decrypts using the per-device session and saves
    /// the message as an outgoing bubble in the correct conversation.
    private func handleSenderSync(_ message: ChatMessage, in context: NSManagedObjectContext) {
        guard let currentUserId = AuthSessionManager.shared.currentUserId else { return }

        let partnerUserId = extractPartnerUserId(from: message.conversationId, myUserId: currentUserId)
        guard !partnerUserId.isEmpty else {
            // This branch is not reachable-by-accident: it is where SENDER_SYNC always ends up.
            //
            // We do send both fields — `buildEnvelope` sets `conversationID` and `senderDevice` on
            // every non-sealed envelope, and SENDER_SYNC is explicitly never sealed. The server
            // blanks them on delivery **on purpose** (`messaging-service/src/envelope.rs`:
            // `sender_device: None` and "conversation_id is intentionally empty: it is
            // server-visible metadata and must not carry E2E semantics"). Observed 2026-08-05, one
            // message id on both sides of a single device:
            //
            //   sent      1aa6abac…-ss-b3ed60ab  conversationId = direct:0a1c609f…:ea134859…
            //   received  conversationId = ''    senderDevice = ''
            //
            // So this is a design contradiction, not a relay bug: SENDER_SYNC routes on metadata
            // the server is designed never to deliver, which means multi-device sync of one's own
            // sent messages cannot work as currently specified. The partner id and sender device
            // have to travel *inside* the ciphertext, where the server neither sees nor strips
            // them — a protocol change, not a patch, so it is not made here. The message id is no
            // fallback either: `-ss-<deviceTag>` carries the *recipient* device, not the sender's.
            //
            // What is fixed here is the diagnosis. The previous line named neither the message nor
            // the second missing field, so fifteen distinct failures read exactly like one failure
            // logged fifteen times.
            Log.error(
                "SENDER_SYNC: unroutable \(message.id) — conversationId='\(message.conversationId)' senderDeviceId='\(message.senderDeviceId)'; both are set on send and blanked by the server by design, so this message cannot be placed in a conversation. The copy of what the other device sent will not appear here.",
                category: "MessageRouter"
            )
            PerformanceMetrics.shared.record(
                .senderSyncUnroutable,
                label: message.senderDeviceId.isEmpty ? "no_conversation_no_device" : "no_conversation"
            )
            return
        }

        let contactId = message.senderDeviceId.isEmpty
            ? message.from
            : MultiDeviceSendCoordinator.sessionKey(userId: message.from, deviceId: message.senderDeviceId)

        let hasSession = CryptoManager.shared.hasSession(for: contactId)

        if hasSession {
            do {
                let decryptResult = try CryptoManager.shared.decryptMessage(message, contactIdOverride: contactId)
                saveSenderSyncMessage(decryptResult.plaintext, original: message, partnerUserId: partnerUserId, in: context)
            } catch {
                Log.error("SENDER_SYNC: decryption failed for contactId=\(contactId.prefix(20))…: \(error)", category: "MessageRouter")
                return
            }
        } else if message.messageNumber == 0 {
            // New device: init receiving session async, then save
            guard !message.senderDeviceId.isEmpty else {
                Log.error("SENDER_SYNC: no senderDeviceId for first message — cannot init session", category: "MessageRouter")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.initAndDecryptSenderSync(
                    message: message,
                    contactId: contactId,
                    partnerUserId: partnerUserId,
                    in: context
                )
            }
        } else {
            Log.error("SENDER_SYNC: no session for \(contactId.prefix(20))… and messageNumber=\(message.messageNumber) > 0 — dropping", category: "MessageRouter")
        }
    }

    /// Extract the OTHER user's ID from a direct conversation ID.
    /// Format: "direct:{sorted_user1}:{sorted_user2}"
    private func extractPartnerUserId(from conversationId: String, myUserId: String) -> String {
        let parts = conversationId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "direct" else { return "" }
        let a = String(parts[1]), b = String(parts[2])
        if a == myUserId { return b }
        if b == myUserId { return a }
        return ""
    }

    /// Save a decrypted SENDER_SYNC message as an outgoing bubble.
    ///
    /// Wire payload is the same binary path as a normal receive (KNST → MessageContent).
    /// Local store uses CTM1 `storagePayload` when the reassembler provides it (C1c).
    private func saveSenderSyncMessage(
        _ decryptedBytes: Data,
        original: ChatMessage,
        partnerUserId: String,
        in context: NSManagedObjectContext
    ) {
        let chat: Chat
        do {
            let resolved = try findOrCreateChat(for: partnerUserId, in: context)
            chat = resolved.0
        } catch {
            Log.error("SENDER_SYNC: failed to resolve chat for \(partnerUserId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        // Decode wire bytes through the same pipeline as inbound chat messages.
        let storagePayload: Data
        let previewText: String
        let e2eRowId: String?
        let mediaAlbum: Shared_Proto_Messaging_V1_MediaAlbumMessage?

        switch ChunkedMessageReassembler.shared.process(data: decryptedBytes, envelopeId: original.id) {
        case .assembled(let text, _, let e2eId, let album, let storage):
            e2eRowId = e2eId
            mediaAlbum = album
            if let storage, !storage.isEmpty {
                storagePayload = storage
                previewText = LocalMessagePayload.decode(storage).previewHint
            } else {
                storagePayload = LocalMessagePayload.encodeText(text)
                previewText = text
            }
        case .legacy(let text):
            e2eRowId = nil
            mediaAlbum = nil
            storagePayload = LocalMessagePayload.encodeText(text)
            previewText = text
        case .profile:
            Log.info("SENDER_SYNC: profile-share carrier, not persisting as text", category: "MessageRouter")
            return
        case .edit:
            Log.info("SENDER_SYNC: edit in sync payload, ignoring", category: "MessageRouter")
            return
        case .incomplete:
            // Multi-chunk SENDER_SYNC: wait for remaining KNST fragments (same reassembler state).
            Log.debug("SENDER_SYNC: chunk incomplete — waiting for more", category: "MessageRouter")
            return
        case .invalid:
            Log.info(
                "SENDER_SYNC: could not decode payload for \(partnerUserId.prefix(8))… — no user content",
                category: "MessageRouter"
            )
            return
        }

        // Typed session-control content types (should not appear as SENDER_SYNC body).
        if SessionControlCodec.op(forContentType: Int(original.contentType)) != nil {
            return
        }

        // Canonical row id: E2E id from KNST when present, else strip multi-device wire suffixes
        // (`-ss-…`, `-ss-…-cN`) so edits/receipts still match the originating device's message id.
        let rowId = Self.senderSyncRowId(e2eMessageId: e2eRowId, wireMessageId: original.id)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id ==[c] %@", rowId)
        fetch.fetchLimit = 1
        do {
            if try context.fetch(fetch).first != nil {
                return // already saved (duplicate delivery / other chunk path)
            }
        } catch {
            Log.error("SENDER_SYNC: failed to deduplicate message \(rowId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        let msg = Message(context: context)
        msg.id = rowId
        msg.fromUserId = original.from
        msg.toUserId = partnerUserId
        msg.timestamp = Date.fromRemoteTimestamp(original.timestamp)
        msg.isSentByMe = true
        msg.deliveryStatus = .sent
        msg.retryCount = 0
        msg.chat = chat

        msg.applyStoredEncryption(plaintextData: storagePayload, contactId: partnerUserId)
        if let mediaAlbum {
            MediaWireCodec.storeThumbnails(from: mediaAlbum, for: rowId)
        }

        chat.applyPreview(text: previewText, timestamp: msg.timestamp)
        context.saveAndLog()

        if !original.senderDeviceId.isEmpty {
            CryptoManager.shared.saveSessionToKeychain(
                for: MultiDeviceSendCoordinator.sessionKey(userId: original.from, deviceId: original.senderDeviceId)
            )
        }
        Log.info("SENDER_SYNC: saved outgoing message in conversation with \(partnerUserId.prefix(8))…", category: "MessageRouter")
    }

    /// Map SENDER_SYNC wire id → local row id (E2E id preferred).
    private static func senderSyncRowId(e2eMessageId: String?, wireMessageId: String) -> String {
        if let e2eMessageId, !e2eMessageId.isEmpty {
            return e2eMessageId.lowercased()
        }
        var id = wireMessageId.lowercased()
        // Strip `-ss-<device>` and optional `-cN` chunk suffix used by MultiDeviceSendCoordinator.
        if let range = id.range(of: "-ss-") {
            id = String(id[..<range.lowerBound])
        }
        return id
    }

    /// Async helper: fetch sender device bundle, init receiving session, then save.
    private func initAndDecryptSenderSync(
        message: ChatMessage,
        contactId: String,
        partnerUserId: String,
        in context: NSManagedObjectContext
    ) async {
        do {
            // SENDER_SYNC from one of our own devices. initReceivingSession below uses only
            // identity / SPK / verifying key — no one-time pre-key — so don't burn one.
            let bundle = try await KeyServiceClient.shared.getPreKeyBundle(
                userId: message.from,
                deviceId: message.senderDeviceId,
                consumeOneTimePrekey: false
            )
            let bundleWithSuite = (
                identityPublic: bundle.identityPublic,
                signedPrekeyPublic: bundle.signedPrekeyPublic,
                signature: bundle.signature,
                verifyingKey: bundle.verifyingKey,
                suiteId: String(bundle.suiteId)
            )
            let decrypted = try CryptoManager.shared.initReceivingSession(
                for: contactId,
                recipientBundle: bundleWithSuite,
                firstMessage: message,
                spkUploadedAt: bundle.spkUploadedAt,
                spkRotationEpoch: bundle.spkRotationEpoch,
                kyberSpkUploadedAt: bundle.kyberSpkUploadedAt,
                kyberSpkRotationEpoch: bundle.kyberSpkRotationEpoch
            )
            saveSenderSyncMessage(decrypted, original: message, partnerUserId: partnerUserId, in: context)

            // Replenish any OTPKs consumed during this session init
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
        } catch {
            Log.error("SENDER_SYNC: initReceivingSession failed for \(contactId.prefix(20))…: \(error)", category: "MessageRouter")
        }
    }
}

/// Client-side block enforcement lookup.
///
/// Under Ghost Mode (sealed sender) the server cannot see the sender of a sealed message,
/// so it does NOT apply server-side block/ban on the default send path — the sealed branch
/// returns before the block check (construct-server messaging-service/grpc.rs). Blocking is
/// therefore enforced client-side, by dropping incoming messages from blocked contacts AFTER
/// they are unsealed/decrypted (the ratchet still advances, so unblocking resumes cleanly).
/// This is the load-bearing block mechanism and the shape the unauthenticated sealed-sender
/// endgame requires — the server can never enforce it there.
///
/// See: construct-docs/decisions/sealed-sender-authenticated-transitional.md
enum BlockedContacts {
    /// Whether `userId` is a blocked contact in the given context. Cheap indexed count on the
    /// `User` entity; safe on the incoming-message hot path. Empty/unknown ids → not blocked
    /// (fail-open: a block is a user-initiated suppression, not a boundary whose lookup failure
    /// should drop legitimate traffic).
    static func isBlocked(_ userId: String, in context: NSManagedObjectContext) -> Bool {
        guard !userId.isEmpty else { return false }
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@ AND isBlocked == YES", userId)
        fetch.fetchLimit = 1
        return ((try? context.count(for: fetch)) ?? 0) > 0
    }
}

#if DEBUG
extension MessageRouter {
    func _testPersistRegularIncomingMessage(
        _ decryptedContent: String,
        message: ChatMessage,
        from otherUserId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) throws {
        try saveMessage(
            for: chat,
            with: message,
            decryptedContent: decryptedContent,
            quotedMessage: nil,
            in: context
        )
        try PersistentACKStore.shared.markProcessedOrThrow(message.id, senderId: otherUserId, in: context)
    }
}
#endif
