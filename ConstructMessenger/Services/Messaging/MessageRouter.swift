//
//  MessageRouter.swift
//  Construct Messenger
//
//  Pure incoming-message pipeline: validate → decrypt via Rust orchestrator → dispatch
//  typed events to MessageRouterDelegate (SessionCoordinator).
//
//  Messages that arrive before their sender's session is ready wait in the core's queue, not
//  here (decisions/first-contact-queue-keyed-by-claimed-device.md). This router keeps only their
//  envelopes, until the core opens them or drops them.
//

import Foundation
import CoreData
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class MessageRouter {

    // MARK: - Delegate

    weak var delegate: (any MessageRouterDelegate)?

    // MARK: - Core Data

    private var viewContext: NSManagedObjectContext?

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    private let chunkReassembler = ChunkedMessageReassembler.shared
    private var processingMessageIds: Set<String> = []

    /// Envelopes of the messages the core is holding in **its** queue (`messageQueuedPendingInit`),
    /// by message id.
    ///
    /// The core owns that queue: which messages wait, in what order, and when they are opened
    /// (`SessionInitCompleted`, `NetworkReconnected`). What it cannot own is the envelope — the
    /// account, the conversation, the server order key — because none of that crosses the seam;
    /// its drain answers with `messageDecrypted(contact, messageId, plaintext)` and nothing else.
    /// Until 2026-09-26 this router kept no envelope, so a message the core opened in a drain had
    /// nowhere to be saved: it was thrown away with the rest of the answer, and the redelivery
    /// that followed found its key already used — a duplicate. This is the platform's half of
    /// that queue: the data only the platform has, keyed by the id the core names it by.
    ///
    /// In memory, like the core's queue: after a restart both are empty, the cursor was held
    /// (`.deferred`), and the server redelivers. Bounded by `coreQueuedTTL`, because a message
    /// the core drops or fails in a drain names no id this map could be cleared by.
    private var coreQueuedEnvelopes: [String: CoreQueuedEnvelope] = [:]
    private struct CoreQueuedEnvelope {
        let message: ChatMessage
        let otherUserId: String
        let heldAt: Date
    }
    private static let coreQueuedTTL: TimeInterval = 600

    private func holdEnvelopeForCoreQueue(_ message: ChatMessage, otherUserId: String) {
        let now = Date()
        coreQueuedEnvelopes = coreQueuedEnvelopes.filter { now.timeIntervalSince($0.value.heldAt) < Self.coreQueuedTTL }
        coreQueuedEnvelopes[message.id] = CoreQueuedEnvelope(message: message, otherUserId: otherUserId, heldAt: now)
    }

    /// Carry out the core's answer to an event that drains its queue — `SessionInitCompleted`,
    /// `NetworkReconnected`.
    ///
    /// A `messageDecrypted` for a held envelope is saved exactly as a live decrypt is (same
    /// `executeRustActions`), its durable-ACK obligation settled and its held cursor released.
    /// Everything else goes through `executeOffRouter`, which logs any router-bound action it has
    /// no envelope for. A message that failed in the drain was not consumed — a failed decrypt
    /// restores the ratchet — so its cursor stays held and the server's redelivery takes it
    /// through the live path, heal and all.
    func resolveCoreDrain(_ actions: [CfeAction], site: String) {
        guard let context = viewContext else {
            SessionActionExecutor.shared.executeOffRouter(actions, site: site)
            return
        }
        SessionActionExecutor.shared.executeOffRouter(actions, site: site) { [coreQueuedEnvelopes] action in
            switch action {
            case .messageDecrypted(_, let messageId, _), .callSignalDecrypted(_, let messageId, _),
                 .controlFrameDecrypted(_, let messageId, _, _):
                return coreQueuedEnvelopes[messageId] != nil
            default:
                return false
            }
        }
        // A call signal the drain opened: dispatched by the account its envelope was held under,
        // as a live one is, and released like a saved message. Until 2026-10-02 only message
        // bodies were taken from a drain — a queued call signal was executed by device id, gated
        // out, and its cursor left held.
        for action in actions {
            guard case .callSignalDecrypted(_, let messageId, _) = action,
                  let held = coreQueuedEnvelopes.removeValue(forKey: messageId) else { continue }
            Self.dispatchCallSignals(in: [action], from: held.otherUserId)
            PersistentACKStore.shared.markProcessed(messageId, senderId: held.otherUserId, in: context)
            _ = PersistentACKStore.shared.settleDurableWrite(messageId, in: context)
            StreamCursorTracker.shared.resolve(messageId: messageId)
        }
        // A control frame the drain opened: handled by the account its envelope was held under.
        for action in actions {
            guard case .controlFrameDecrypted(_, let messageId, _, _) = action,
                  let held = coreQueuedEnvelopes.removeValue(forKey: messageId) else { continue }
            handleControlFrames(in: [action], messageId: messageId, from: held.otherUserId, in: context)
            _ = PersistentACKStore.shared.settleDurableWrite(messageId, in: context)
            StreamCursorTracker.shared.resolve(messageId: messageId)
        }
        for action in actions {
            guard case .messageDecrypted(_, let messageId, _) = action,
                  let held = coreQueuedEnvelopes.removeValue(forKey: messageId) else { continue }
            do {
                let (chat, _) = try findOrCreateChat(for: held.otherUserId, in: context)
                _ = executeRustActions([action], for: held.message, chat: chat, otherUserId: held.otherUserId, in: context)
                if PersistentACKStore.shared.settleDurableWrite(messageId, in: context) {
                    Log.error(
                        "PersistAck unmet for \(messageId.prefix(8))… after a core drain (\(site)) — saved, but nothing durable remembers handling it",
                        category: "MessageRouter"
                    )
                }
                StreamCursorTracker.shared.resolve(messageId: messageId)
                Log.info(
                    "SESSION_STATE[core_drain_saved]: \(messageId.prefix(8))… from \(held.otherUserId.prefix(8))… opened by the core's drain (\(site))",
                    category: "SessionInit"
                )
            } catch {
                Log.error(
                    "Core drain (\(site)) opened \(messageId.prefix(8))… but its chat could not be found or created: \(error)",
                    category: "MessageRouter"
                )
            }
        }
    }

    /// The call signals in `actions`, as the proto bytes CallManager reads. Separate so the
    /// sender it is dispatched under is visible at the call site — the account, never the device
    /// id the action carries.
    static func callSignals(in actions: [CfeAction]) -> [Data] {
        actions.compactMap { action in
            if case .callSignalDecrypted(_, _, let protoBytes) = action { return protoBytes }
            return nil
        }
    }

    private static func dispatchCallSignals(in actions: [CfeAction], from account: String) {
        for bytes in callSignals(in: actions) {
            if let signal = CallManager.decodeSignalProto(from: bytes) {
                CallManager.shared.handleCallSignalProto(from: account, signal: signal)
            } else {
                Log.error("Call signal from \(account.prefix(8))… failed to decode", category: "MessageRouter")
            }
        }
    }

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

    // MARK: - Envelopes the core is holding

    /// Release envelopes the core no longer holds — dropped with its queue, or given up on — and
    /// let the stream cursor past them. Never persisted, so nothing else would ever resolve them.
    func releaseCoreQueued(_ messageIds: [String]) {
        for id in messageIds {
            coreQueuedEnvelopes.removeValue(forKey: id)
            StreamCursorTracker.shared.resolve(messageId: id)
        }
    }

    /// The devices of `peerId` that envelopes waiting in the core were sent from, as their sender
    /// certificates named them — at first contact the only place those devices are known.
    func claimedDevicesAwaitingCore(ofPeer peerId: String) -> [String] {
        coreQueuedEnvelopes.values
            .filter { $0.otherUserId == peerId && !$0.message.senderDeviceId.isEmpty }
            .map(\.message.senderDeviceId)
    }

    /// Whether a redelivery can be dropped without unsealing it.
    ///
    /// The expensive part of routing an incoming message is recovering the sealed sender — an
    /// Ed25519 verification — and it runs before anything knows the message is a duplicate. At 51
    /// redeliveries a second that is a saturated core (build 584: CPU 100–128 %, thermal
    /// nominal → fair, 99.6 % of incoming already processed).
    ///
    /// Both reasons the full path still has work to do for a duplicate can be answered from the
    /// envelope, without opening the seal:
    ///
    /// - **The orphaned-init exception.** A msgNum-0 init may need re-processing when the session
    ///   was lost after the ACK, and deciding that needs the unsealed content type and sender. So
    ///   `msgNum == 0` never takes this path — it was 1.1 % of the traffic.
    /// - **The receipt resend.** A duplicate re-sends a delivery receipt at most once per window,
    ///   and the throttle is keyed on the message id. While it is still suppressing, there is no
    ///   receipt to send and therefore no need for the sender the unseal would recover.
    ///
    /// Deliberately *not* keyed on "is this sealed": an identified redelivery has the same nothing
    /// to do, and a rule that applies to one wire form and not the other is the kind of split this
    /// codebase keeps paying for.
    nonisolated static func canSkipRedeliveryBeforeUnseal(
        isProcessed: Bool,
        messageNumber: UInt32,
        receiptStillThrottled: Bool
    ) -> Bool {
        guard isProcessed else { return false }
        guard messageNumber > 0 else { return false }
        return receiptStillThrottled
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
        // A copy the core is still holding came round again (the server redelivers a held
        // cursor). This pass now owns it; if the core queues it once more, the envelope is kept
        // again below.
        coreQueuedEnvelopes.removeValue(forKey: message.id)

        // A per-device copy from a peer, addressed to one of our *siblings*.
        //
        // Delivery is per account, not per device: `messaging-service/src/core.rs` writes each
        // envelope to every one of the recipient's per-device streams. So once a sender fans out,
        // an account with three devices receives, on each of them, the two copies meant for the
        // other two — and only one session can open each.
        //
        // Without this the foreign copies take the ordinary decrypt path, fail, and on
        // `messageNumber == 0` reach for a key bundle and can drive session healing — which
        // archives a healthy session. That is the churn the device tag exists to prevent, and it
        // became reachable the day recipient copies started going out per device (2026-08-30).
        //
        // `.undecidable` means we cannot tell — a peer device we never pinned looks the same as a
        // sibling's copy — and it is treated as ours: attempting a copy costs a failed decrypt,
        // discarding one loses a message from the transcript.
        // §D: the device that wrote this copy. A local, not a map keyed by message id — the naming
        // and the decrypt that consumes it are both in this function, and a dictionary here would
        // be one more thing to expire.
        //
        // Written twice below, and only the second one fires in practice. The wire-id tag is read
        // here because it is the only answer available *before* the unseal; on a sealed delivery
        // there is no tag to read, because the relay rebuilds the envelope from `sealed_inner` and
        // stamps its own id (measured 2026-09-06: 32 tagged copies sent, 0 of 773 incoming ids
        // carrying a marker). The certificate answers it after the unseal instead. The branch is
        // kept for the identified path, which still delivers `Envelope.message_id` verbatim.
        var namedSenderDevice: String?

        if DeviceCopyWireId.audience(of: message.id) == .recipient {
            let reading = DeviceCopyWireId.read(
                wireId: message.id,
                ourDeviceId: AuthSessionManager.shared.currentDeviceId,
                tagger: SenderSyncDeviceTag.Tagger.current,
                peerIdentityKeys: PeerDeviceRegistry.shared.identityKeys(of: message.from),
                peerDeviceSetIsComplete: PeerDeviceRegistry.shared.deviceSetIsKnown(for: message.from)
            )
            let verdict = reading.verdict
            PerformanceMetrics.shared.record(.deviceCopyVerdict, label: verdict.metricLabel)
            // §D. The tag verification just named the device that wrote this copy; remembered here
            // so the decrypt below asks that device's session instead of walking, and so a failure
            // is attributed to it instead of to whichever session the walk happened to try last.
            if let sender = reading.senderDevice {
                namedSenderDevice = sender
                PerformanceMetrics.shared.record(.deviceCopyVerdict, label: "sender_named")
            }
            if verdict == .foreign {
                Log.debug(
                    "FAN-OUT: \(message.id.prefix(8))… is addressed to another of our devices — skipping",
                    category: "MessageRouter"
                )
                PersistentACKStore.shared.markProcessed(message.id, senderId: message.from, in: context)
                return
            }
        }

        // Redelivery fast path — **before** the unseal, which is the whole point.
        //
        // The server ignores `since_cursor` and replays below the watermark, so the stream is
        // mostly messages we have already handled. Build 584, four minutes on one device:
        //
        //     12 252  incoming            (51/s)
        //     12 204  "already-processed"  (99.6 %)
        //     12 170  sealed-sender signature verifications
        //     CPU 100–128 % sustained, thermal nominal → fair
        //
        // Every one of those paid an Ed25519 verification and a ten-line RAW dump *before*
        // reaching the duplicate check that threw the result away. The redelivery is the server's
        // defect; burning a core on it is ours.
        //
        // Nothing is lost by leaving early, because the two things the full path still does for a
        // duplicate both have pre-unseal answers: the orphaned-init exception is `msgNum == 0`
        // only (138 of 12 251 here — 1.1 %), and the receipt resend is already suppressed by the
        // throttle, which is keyed on the message id. The exit is `.durable`, exactly as the
        // duplicate branch below produces, so cursor bookkeeping is unchanged — the `defer` above
        // still settles and reports.
        if Self.canSkipRedeliveryBeforeUnseal(
            isProcessed: PersistentACKStore.shared.isProcessed(message.id, in: context),
            messageNumber: message.messageNumber,
            receiptStillThrottled: ReceiptResendThrottle.shared.isThrottled(messageId: message.id)
        ) {
            PerformanceMetrics.shared.record(.redeliverySkippedBeforeUnseal, label: "msgNum>0")
            return
        }

        // STEALTH: resolve sender from sealed inner before any routing.
        // `from` is empty for ConstructSEALED messages — decrypt to recover sender ID.
        var message = message
        if message.from.isEmpty && !message.sealedInnerData.isEmpty {
            // A copy sealed to one of our other devices is not a failure and must not be treated
            // as one: it can never open here, so deferring it spends a redelivery and a stream
            // cursor round-trip on a certainty, and counting it hides real unseal failures inside
            // the expected ones. Checked before the attempt because the attempt is what costs.
            if let target = StealthSenderService.otherDeviceAddressed(
                sealedInnerBytes: message.sealedInnerData,
                ourDeviceId: SessionAddressing.localIdentity()
            ) {
                // Which device, and whether it is currently ours. The drop is the same in all
                // three cases — this copy can never open here — but a sibling's copy off the
                // account stream is an expected duplicate, and a copy for a device outside the
                // set is either a misroute or a revoke's backlog. The line that said only
                // "another of our devices" claimed the first while checking neither.
                //
                // No ERROR on `.notOurs`, deliberately. The first version raised one, and the
                // next run produced 24 of them from a single revoke: the mailbox still held
                // copies addressed to the device that had just been removed, and every one of
                // them read as a routing defect. The count is the instrument; a burst right
                // after a revoke is expected, a count that keeps rising without one is not.
                let origin = StealthSenderService.classifyOtherDevice(
                    target,
                    ourDeviceIds: MultiDeviceSendCoordinator.shared.knownOwnDeviceIds(myUserId: currentUserId)
                )
                Log.debug(
                    "STEALTH: \(message.id.prefix(8))… is sealed to \(target.prefix(8))… (\(origin.rawValue)) — dropping, not ours to open",
                    category: "MessageRouter"
                )
                PerformanceMetrics.shared.record(.stealthCopyForSibling, label: origin.rawValue)
                streamOutcome = .durable
                return
            }
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
            // §D, the half that works. The certificate names the writing device, sealed to us and
            // covered by the server signature, so the decrypt below asks that one session instead
            // of walking the peer's devices. The tag branch above cannot supply this on a sealed
            // delivery — see `ResolvedSender.senderDeviceId` — and every delivery is sealed.
            if !message.senderDeviceId.isEmpty {
                namedSenderDevice = message.senderDeviceId
                PerformanceMetrics.shared.record(.deviceCopyVerdict, label: "sender_named")
            }
            // Nothing branches on `resolved.contentType` beyond this point for the four types that
            // moved into the frame (12/14/25/26) — it is UNSPECIFIED for all of them now. Only
            // END_SESSION (21) and SESSION_RESET_INIT (24) still say anything here.
        }

        // A message replayed from the confirm hold or the pending queue arrives here already
        // resolved — `from` filled, sealed bytes spent — so the branch above does not run, but
        // the device it named is still on the message. Without this the replay asked about the
        // pinned device's session, found it down, and tore the peer down over a message whose
        // own session was alive (stand, 2026-09-21 18:38:35: `device=pinned, hasSession=false`
        // on two replays, then END_SESSION to the sibling).
        if namedSenderDevice == nil, !message.senderDeviceId.isEmpty {
            namedSenderDevice = message.senderDeviceId
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
        Log.debug("   messageNumber: \(message.messageNumber) kind: \(message.initKind) payload: \(message.rawPayload.count)B", category: "MessageRouter")
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
            // Never re-process control carriers as "orphaned init" — END_SESSION / sender-sync
            // already failed or completed; replaying them loops session teardown. A handshake is
            // the header, at any message number (`decisions/sessions-renew-by-sending.md`).
            let isOrphanedInit = message.initKind == .handshake
                && !message.isEndSession
                && !message.isSenderSync
                && !CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: otherUserId)
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
                //
                // Not for a SENDER_SYNC: it is our own account's copy, there is no sender waiting
                // for a checkmark, and on a pending-messages replay its `to` is empty — the
                // "other side" of a message from ourselves is then nobody at all.
                if message.isSenderSync {
                    // nothing owed
                } else if ReceiptResendThrottle.shared.shouldSend(messageId: message.id) {
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

        // 2a. Own-account traffic that is *not* a SENDER_SYNC.
        //
        // Every own-device copy is addressed `from == to == us`, and step 2 is the only thing that
        // legitimately arrives in that shape. Anything else self-addressed is one of our own sends
        // handed straight back by the server's per-device fan-out — most often a delivery receipt,
        // whose real content type rides inside the KNST frame, so the outer envelope reads
        // DIRECT_MESSAGE and nothing above this point can tell it from a message by a contact.
        //
        // Without this guard `otherUserId` — `from == me ? to : from` — answers **me**, and the
        // whole path below treats us as the person on the other side. On the three-device stand
        // 2026-08-27 that minted a chat with ourselves, ran the concurrent-init tie-break against
        // our own device, fetched our own pre-key bundle, and sent a SESSION_RESET_INIT to
        // ourselves — which archived a healthy session and re-initialised it. The chat in the list
        // was the cheap half.
        //
        // The receipt that seeded it is suppressed at source in `sendDeliveryReceipt`; this stays
        // because it also covers copies already on the server and sends by an older build.
        if SessionAddressing.isOwnReflection(
            from: message.from, to: message.to, ourAccountId: currentUserId
        ) {
            Log.info(
                "Self-addressed \(message.id.prefix(8))… (ct=\(message.contentType)) — our own traffic reflected back by the fan-out, not a peer message",
                category: "MessageRouter"
            )
            PerformanceMetrics.shared.record(.selfAddressedDropped, label: "ct_\(message.contentType)")
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            return
        }

        // A SESSION_RESET_INIT (content type 24) from a build before 2026-09-27 is not special any
        // more: it is a message carrying the handshake header, and it opens like one below. Its
        // payload is a control string, discarded in `executeRustActions`.

        // 3. END_SESSION (21) from a build before 2026-09-27: acknowledged and nothing else. It
        //    named no state, so nothing here could tell whether it was about the one we hold — the
        //    decryption error below does.
        if message.isEndSession {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.info("END_SESSION from \(otherUserId.prefix(8))… — retired message type, acknowledged and ignored", category: "MessageRouter")
            return
        }

        // 3a. DECRYPTION_ERROR (28): the peer could not read something we sent it. The core opens
        //     it and decides — retire our current state when it names that state, resend the
        //     named message once — and nothing here second-guesses it.
        if message.isDecryptionError {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            delegate?.messageRouter(
                self,
                receivedDecryptionError: PeerAddress(account: otherUserId, device: message.senderDeviceId),
                payload: message.rawPayload,
                opened: message.envelopeSession != nil
            )
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
        //    A real handshake means the sender fetched our *current* public keys (via a fresh
        //    invite) and started a new session — a legitimate re-contact, so clear the deleted flag
        //    and process normally (a new chat will be created by findOrCreateChat below).
        //    Anything else is an old session we no longer have keys for — skip it.
        //    Exception: if this exact message is already in our pending queue (a previous heal
        //    attempt started and failed), the server is re-delivering a stuck undecryptable message.
        //    Do NOT resurrect the contact in that case — just ACK and discard.
        //
        //    This condition used to be `messageNumber == 0`, which is not what it was reading as.
        //    A DH sending chain also starts at 0, so a mid-session leftover from the deleted
        //    contact's replayed backlog satisfied it — and the server replays that backlog on
        //    every reconnect (`since_cursor` is not honoured). The contact came back after every
        //    single deletion, reported on device 2026-08-19. Same misreading as the RESPONDER init
        //    guard; same classifier fixes both.
        if DeletedContactsStore.shared.isDeleted(otherUserId) {
            let kind = message.initKind
            if kind == .handshake {
                // Guard: don't resurrect a deleted contact for a message we already queued
                // but couldn't decrypt. This prevents an infinite delete→re-appear loop when
                // the server keeps re-delivering stuck undecryptable messages.
                if coreQueuedEnvelopes[message.id] != nil {
                    Log.debug("Skipping stale pending message \(message.id.prefix(8))… from deleted contact — not resurrecting", category: "MessageRouter")
                    PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "stale_pending")
                    return
                }
                Log.info("Handshake from previously-deleted contact \(otherUserId.prefix(8))… (msgNum=\(message.messageNumber)) — clearing deleted flag", category: "MessageRouter")
                DeletedContactsStore.shared.remove(otherUserId)
                // Fall through to normal processing below.
            } else {
                Log.debug("\(kind) from deleted contact \(otherUserId.prefix(8))… (msgNum=\(message.messageNumber)) — not resurrecting, answering with a decryption error", category: "MessageRouter")
                // Answered, not just dropped. The deletion forgot the session, so the core cannot
                // read this and sends its writer a decryption error; the writer opens a new state
                // and resends, and that handshake is what the branch above resurrects the contact
                // on. On 2026-09-04 a pruned contact's peer sent msgNum 1–5 into this branch, every
                // one dropped and every one *sent* on their screen: the handshake never came,
                // because a peer on a healthy session has no reason to send one. The deletion
                // announced an END_SESSION for that until 2026-09-27; now nothing is sent until
                // the peer writes (`decisions/sessions-renew-by-sending.md`).
                answerWithDecryptionError(message, from: otherUserId, in: context)
                PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "deleted_contact")
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
        //
        // Asked of the device the certificate names, when it names one. By account this
        // resolved to the pinned device, so a message from the peer's *other* device while the
        // pinned session was down — a reset in flight, a teardown just applied — read as "no
        // session, mid-ratchet" and answered with an END_SESSION for the whole peer, though the
        // session it was actually sent on was alive and listed two lines below as the first
        // decrypt candidate. An unnamed sender still falls back to the pinned device — named here
        // rather than resolved inside `hasSession`, which takes a device since step 6.
        let sessionOwner = namedSenderDevice ?? SessionAddressing.pinnedDevice(ofPeer: otherUserId)
        let hasSession = sessionOwner.map {
            CryptoManager.shared.restoreSession(for: $0)
            return CryptoManager.shared.hasSession(for: $0)
        } ?? false
        Log.info("SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., device=\(namedSenderDevice.map { String($0.prefix(8)) } ?? "pinned"), hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")
        
        if !hasSession {
            if namedSenderDevice == nil {
                PerformanceMetrics.shared.record(.firstContactUnattributed, label: sessionOwner == nil ? "none" : "pinned")
            }
            // Only the named device, never the pinned one: the core opens a session from the
            // sender certificate alone (`decisions/first-message-opens-without-the-server.md`), so
            // a message that names no device has nothing to open with whichever device it is
            // filed under. Until 2026-10-04 it was filed under the pinned device and the core then
            // refused it with SENDER_CERTIFICATE_MISSING.
            if let outcome = preflightWithoutSession(
                message,
                from: otherUserId,
                claimed: namedSenderDevice,
                chat: chat,
                isNewChat: isNewChat,
                in: context
            ) {
                streamOutcome = outcome
                return
            }
            // Otherwise to the core, under the claimed device, like any other message: with no
            // session it queues it and answers `.openReceiving` (or
            // `.messageQueuedPendingInit` behind an open already under way), handled below.
        }

        // Rust orchestrator is the SINGLE decrypt path — no Swift fallback.
        // Изъян 4: If orchestratorCore is nil (e.g. Keychain locked after reboot),
        // attempt a one-shot reload before giving up.
        if CryptoManager.shared.orchestratorCore == nil {
            Log.info("OrchestratorCore nil — attempting reload", category: "MessageRouter")
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        guard CryptoManager.shared.orchestratorCore != nil else {
            Log.error("OrchestratorCore still nil after reload — holding \(message.id.prefix(8))… from \(otherUserId.prefix(8))… for redelivery", category: "MessageRouter")
            if isNewChat { context.delete(chat) }
            // Transient (Keychain locked / core not loaded): don't advance — let the server
            // re-deliver after the core recovers rather than acking an unprocessed message.
            streamOutcome = .deferred
            return
        }
        // One session reads this: the one the message names. The sender certificate or the
        // session envelope names the writing device on every sealed delivery, so there is nothing
        // to search. Until 2026-10-04 an unnamed message was tried against each of the peer's
        // device sessions in an order the core planned (`plan_receiving_decrypt`, removed in core
        // 0.34.0); only an unsealed message from a peer — TUI, a DEBUG build with sealing off —
        // still names nobody, and it goes to the pinned device alone. With no session the core
        // queues it under the named device (`preflightWithoutSession` refused it otherwise).
        guard let device = sessionOwner,
              let event = buildIncomingEvent(message: message, otherUserId: otherUserId, asDevice: device)
        else {
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
            Log.error("handleEvent threw for \(message.id.prefix(8))…: \(error) — dropped", category: "MessageRouter")
            // Mark as processed so BackgroundFetch does not re-process this undecryptable
            // message on every background cycle (which would recreate ghost contacts and cause
            // Core Data validation errors). A throw is the core refusing the event, not a
            // session failing to read it, so there is no state to name in a decryption error.
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
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
                // Since the core change of 2026-08-07 the two causes this was written for — the
                // init lock and the END_SESSION cooldown — no longer answer with an empty list:
                // the first returns `messageQueuedPendingInit`, the second is gone with END_SESSION
                // (2026-09-27). The branch stays because a *new* empty verdict must not be silent.
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

        switch OrchestratorActionPlan.routingVerdict(from: actions) {
        case .decrypted:
            // Disposition is observed for metrics/signals only. Incomplete multi-chunk must
            // NOT hold the stream watermark (one partial media message would stall every
            // later cursor for the device). Reassembly that never completes is reported by
            // `.chunkReassemblyExpired`; durable reassembly is the real fix.
            _ = executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
            return
        case .callSignalDecrypted:
            // A call signal, named by the core — by the envelope's type or, since core 0.29, by
            // the KNST frame's (every sealed one).
            //
            // Dispatched here, by account: the core names the sender by device, and CallManager's
            // gate (blocked, callable contact) reads an account — handed the device id it dropped
            // every signal (2026-10-02, after core 0.29). Recorded as processed: the core asked
            // for a durable record, and this path wrote none until 0.29 sent every signal here.
            _ = executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
            Self.dispatchCallSignals(in: actions, from: otherUserId)
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            return
        case .controlFrameDecrypted:
            // A receipt, a card, a profile, a heartbeat — named by the core from the KNST frame
            // (core 0.30). Never a transcript row.
            _ = executeRustActions(actions, for: message, chat: chat, otherUserId: otherUserId, in: context)
            handleControlFrames(in: actions, messageId: message.id, from: otherUserId, in: context)
            return
        case .unreadable:
            // Nothing held for the device reads it and it carries no handshake. The core recorded
            // it and built the decryption error to its writer (sealed messages); executing the
            // actions sends it. The writer resends the message on the state it opens next, so the
            // cursor moves past this copy.
            Log.info("SESSION_STATE[unreadable]: \(message.id.prefix(8))… from \(otherUserId.prefix(8))… msgNum=\(message.messageNumber) — the writer is told", category: "SessionInit")
            PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "unreadable")
            SessionActionExecutor.shared.execute(actions)
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            if isNewChat { context.delete(chat) }
            return
        case .openReceiving(let lostDevice):
            // The core queued this message under `lostDevice` — the device the sender certificate
            // named, or the pinned one — and granted the open. First contact and a new state over
            // one held alike end here (the held one becomes a previous state): the core holds the message and its certificate, this side keeps its
            // envelope, and the open (`SessionCoordinator.openReceiving`) asks nothing of the
            // server — the key comes from the certificate.
            Log.info("SESSION_STATE[first_message]: \(message.id.prefix(8))… msgNum=\(message.messageNumber) queued in the core for \(PeerAddress(account: otherUserId, device: lostDevice)) — opening", category: "SessionInit")
            SessionActionExecutor.shared.execute(actions)
            holdEnvelopeForCoreQueue(message, otherUserId: otherUserId)
            delegate?.messageRouter(
                self,
                canOpenReceiving: PeerAddress(account: otherUserId, device: lostDevice),
                for: message
            )
            // Held in the core until the open drains it or drops it — hold the cursor.
            streamOutcome = .deferred
            if isNewChat { context.delete(chat) }
            return
        case .duplicate:
            // Handled before: in the core's ACK cache, in our DB, or — since the ratchet names
            // it — a position whose key a first-message init or an earlier copy already used.
            // Recorded as processed so the next copy stops at our own ACK check; the cursor
            // moves past it (`.durable`). Held, it would come back as this same duplicate on
            // every redelivery.
            SessionActionExecutor.shared.execute(actions)
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.debug(
                "Duplicate named by the core — \(message.id.prefix(8))… msgNum=\(message.messageNumber), recorded and dropped",
                category: "MessageRouter"
            )
            if isNewChat { context.delete(chat) }
            return
        case .malformed:
            // Can never open: decrypt uses the parser that just refused it. Recorded and passed,
            // like a duplicate; nothing is answered — there is no state in it to name. The
            // executor logs the core's reason (the `notifyError` beside the verdict).
            SessionActionExecutor.shared.execute(actions)
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            Log.info(
                "Malformed payload named by the core — \(message.id.prefix(8))…, recorded and dropped",
                category: "MessageRouter"
            )
            if isNewChat { context.delete(chat) }
            return
        case .messageQueuedPendingInit(let contactId, let queuedCount):
            // Held inside the core, drained on SessionInitCompleted or NetworkReconnected. The
            // watermark must not move past a message the core has not finished with, and the
            // envelope has to be kept: the drain names the message by id only (`resolveCoreDrain`).
            SessionActionExecutor.shared.execute(actions)
            holdEnvelopeForCoreQueue(message, otherUserId: otherUserId)
            Log.info(
                "SESSION_STATE[queued_in_core]: \(message.id.prefix(8))… held behind session init for \(contactId.prefix(8))… (\(queuedCount) waiting)",
                category: "SessionInit"
            )
            streamOutcome = .deferred
            if isNewChat { context.delete(chat) }
            return
        case .none:
            break
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
            case .controlFrameDecrypted:         return "controlFrameDecrypted"
            case .sendDecryptionError:           return "sendDecryptionError"
            case .openReceiving:                 return "openReceiving"
            case .saveToSecureStore:             return "saveToSecureStore"
            case .notifyNewMessage:              return "notifyNewMessage"
            case .persistAck:                    return "persistAck"
            case .pruneAckStore:                 return "pruneAckStore"
            case .checkAckInDb:                  return "checkAckInDb"
            case .messageQueuedPendingInit:      return "messageQueuedPendingInit"
            case .duplicateDropped:              return "duplicateDropped"
            case .malformedDropped:              return "malformedDropped"
            case .scheduleTimer:                 return "scheduleTimer"
            case .cancelTimer:                   return "cancelTimer"
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
            // the genuinely undecided remainder: QUEUE_FULL / ROUTING_ERROR notifications. Those mean a message the peer sent is not in the transcript and
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

    /// This builder is only ever reached by carriers the core reads as ratchet messages: END_SESSION
    /// (21) and DECRYPTION_ERROR (28) exit above, before any decryption. The event's `is_control`
    /// flag, which told the core to archive the session instead, went with END_SESSION on
    /// 2026-09-27. `assertNotControlCarrier` makes the precondition checkable instead of assumed.
    func assertNotControlCarrier(_ message: ChatMessage, path: String) {
        guard message.isEndSession || message.isDecryptionError else { return }
        // Reaching here means a control carrier slipped past its early exit — the sealed remap
        // missing is the way it could happen. The core would then try to unpack a sealed error box
        // as a wire payload and answer it as an unreadable message — a decryption error about a
        // decryption error. ERROR + metric so it is not a silent wrong answer.
        Log.error(
            "ROUTING[control_reached_wire_path]: ct=\(message.contentType) message \(message.id.prefix(8))… reached \(path) — it should have early-exited",
            category: "MessageRouter"
        )
        PerformanceMetrics.shared.record(
            .controlCarrierReachedWirePath,
            label: "ct=\(message.contentType)"
        )
    }

    /// Build a typed `CfeIncomingEvent.messageReceived` from a server message.
    private func buildIncomingEvent(
        message: ChatMessage,
        otherUserId: String,
        asDevice: String? = nil
    ) -> CfeIncomingEvent? {
        assertNotControlCarrier(message, path: "buildIncomingEvent")
        // A message without its wire payload cannot be decrypted: the core reads everything from
        // it. There was a fallback here that rebuilt a payload as JSON — ciphertext and keys as
        // arrays of integers — which the core could not parse, so it never opened a message;
        // removed 2026-09-29 with the event's parsed-field copies.
        guard !message.rawPayload.isEmpty else {
            Log.error("buildIncomingEvent: empty rawPayload for \(message.id.prefix(8))… — nothing to decrypt", category: "MessageRouter")
            return nil
        }

        // Seam: the orchestrator keeps the session under the sender's device id. `otherUserId` is
        // an account id everywhere above this line — the transcript, the conversation, the
        // contact row — and stays one; only what crosses into the core is translated.
        //
        // Which device is now the caller's to decide, because an account has several and only
        // decryption can say which one sent this. `pinnedDevice(ofPeer:)` remains the answer when
        // the caller has nothing better — that is the single-device case, unchanged.
        guard let contactId = asDevice ?? SessionAddressing.pinnedDevice(ofPeer: otherUserId) else {
            Log.error("buildIncomingEvent: cannot name a device for \(otherUserId.prefix(8))… — no pinned identity key", category: "MessageRouter")
            return nil
        }
        return .messageReceived(
            messageId: message.id,
            from: contactId,
            data: message.rawPayload,
            contentType: message.contentType,
            senderCertificate: message.senderCertificate,
            envelopeSession: message.envelopeSession
        )
    }

    /// What `executeRustActions` did with the decrypted body — feeds stream-cursor disposition.
    private enum DecryptBodyDisposition {
        /// Fully handled (or terminal drop) for this envelope.
        case terminal
        /// Multi-chunk reassembly still waiting — hold stream cursor; do not pretend durable.
        case incompleteReassembly
    }

    /// Execute typed actions returned by `OrchestratorCore.handleEvent`.
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
            if case .messageDecrypted(_, _, let plaintext) = action {
                // The action names the peer by device, because that is what the core keeps the
                // session under. Everything downstream of here — the transcript, the chat row,
                // the receipt, the intake key — is keyed by account, and this function was called
                // with that account id. Taking the action's contact id would file the message
                // under a device nothing else in the app knows about.
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
                if BlockedContacts.isBlocked(otherUserId) {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    Log.info("SECURITY[block_drop]: suppressed message \(message.id.prefix(8))… from blocked \(otherUserId.prefix(8))… (ratchet advanced; no store/notify/receipt)", category: "MessageRouter")
                    continue
                }

                // A SESSION_RESET_INIT from a build before 2026-09-27 opens like any message with
                // the handshake header, and its payload is a control string. Its type rides on the
                // unsealed content type, not in the plaintext frame, so nothing below would
                // recognise it — a stand run on 2026-09-26 showed it landing in the transcript as a
                // "$<uuid>" bubble.
                if message.isSessionResetInit {
                    Log.info("SESSION_RESET_INIT payload discarded (not user-visible, content_type=24) — \(message.id.prefix(8))…", category: "MessageRouter")
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                }

                // ── A control frame is the core's to name ─────────────────────────────────
                // Call signal (12), heartbeat (13), receipt (14), ping/ready (25/26), contact card
                // (27) and profile (29) carry their type in KNST byte 5, inside the ciphertext —
                // the server sees a generic envelope. Since core 0.30 the core reads the frame and
                // hands each over as `callSignalDecrypted` / `controlFrameDecrypted`, so a decrypted
                // message never carries one here. If one does, the core and this app disagree
                // about the frame: say so and drop it — a control payload must never become a
                // transcript row. decisions/sealed-content-type-inside-the-plaintext-frame.md
                if let control = ChunkedMessageCodec.controlFrame(plaintext),
                   ContentTypeRouting.disposition(forFrameContentType: control.contentType) == .silentControl {
                    Log.error("Control frame ct=\(control.contentType) from \(otherUserId.prefix(8))… reached the body path — the core should have named it", category: "MessageRouter")
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                }
                if let control = ChunkedMessageCodec.controlFrame(plaintext),
                   ContentTypeRouting.disposition(forFrameContentType: control.contentType) == .notCarried {
                    // A peer speaking a dialect we do not have. Fall through to the body pipeline
                    // rather than dropping it silently.
                    //
                    // Was `!= 0, != 1` — "known" spelled as two literals, which quietly counted
                    // SENDER_SYNC and every type handled above as unknown. The vectors name the
                    // set no producer frames, so this now logs exactly that.
                    Log.info("Unknown framed content type \(control.contentType) from \(otherUserId.prefix(8))… — treating as a message body", category: "MessageRouter")
                }

                // Profile from a build before content type 29: recognised by its layout, as it
                // always was. Read for one release; ignored once a typed profile is held.
                if let profile = ProfileShareData.fromBinaryData(plaintext) {
                    ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId)
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                } else if let str = String(data: plaintext, encoding: .utf8),
                          let profile = ProfileSharingManager.shared.parseProfileMessage(str) {
                    ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId)
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
                        ProfileSharingManager.shared.handleProfileMessage(profile, from: otherUserId)
                    }
                    PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
                    continue
                case .reaction(let targetMessageID, let emoji, let action, let timestampMs):
                    handleIncomingReaction(
                        targetMessageID: targetMessageID,
                        emoji: emoji,
                        action: action,
                        payloadTimestampMs: timestampMs,
                        fallbackTimestampMs: ReactionStore.envelopeTimestampMs(message.timestamp),
                        from: otherUserId,
                        envelopeId: message.id,
                        in: context
                    )
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


    /// `MessageContent.reaction` is metadata on the target, never a transcript row.
    /// Apply then ACK. An invalid payload is still ACKed so it cannot redeliver
    /// through `decodeAssembled`'s empty-text fallback.
    private func handleIncomingReaction(
        targetMessageID: String,
        emoji: String,
        action: Shared_Proto_Messaging_V1_ReactionAction,
        payloadTimestampMs: Int64,
        fallbackTimestampMs: Int64,
        from otherUserId: String,
        envelopeId: String,
        in context: NSManagedObjectContext
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let decision = ReactionStore.applyIncoming(
            targetMessageId: targetMessageID,
            reactorUserId: otherUserId,
            actionRawValue: action.rawValue,
            emoji: emoji,
            payloadTimestampMs: payloadTimestampMs,
            fallbackTimestampMs: fallbackTimestampMs,
            nowMs: nowMs,
            in: context
        )
        if decision == .dropInvalid {
            Log.error(
                "Invalid reaction envelope \(envelopeId.prefix(8))… target=\(targetMessageID.prefix(8))… from \(otherUserId.prefix(8))… — ACK, not a chat row",
                category: "MessageRouter"
            )
        } else {
            Log.info(
                "Reaction on \(targetMessageID.prefix(8))… from \(otherUserId.prefix(8))… \(decision)",
                category: "MessageRouter"
            )
        }
        PersistentACKStore.shared.markProcessed(envelopeId, senderId: otherUserId, in: context)
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
        // HEARTBEAT announced on the OUTER envelope — a sender running a build from before
        // 2026-08-17, when the type moved into KNST byte 5. Kept so those peers are still
        // understood; new senders are caught earlier, before this function.
        //
        // No receipt either way: a heartbeat has no row on the sender's side, so a receipt could
        // never move anything. (The old comment claimed the peer "treats a heartbeat as answered
        // when the receipt comes back" — nothing on the sending side reads it; stream liveness is
        // tracked by `lastHeartbeatDate` off the stream-level heartbeatAck, a different mechanism.)
        if message.contentType == WireMessageKind.heartbeatContentType {
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
                MediaWireCodec.receiveAlbum(mediaAlbum, for: canonicalId)
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

    /// What happens to a message with no session **before** it goes to the core — the facts the
    /// core cannot see. `nil` hands it to the core, which queues it under `claimed` and grants the
    /// open (`.openReceiving`), or queues it behind an open already under way
    /// (`.messageQueuedPendingInit`).
    ///
    /// This was `handleFirstMessage` until 2026-09-26, which also queued the message in
    /// `PendingSessionQueue`, keyed by account, and asked for the bundle itself. The queue is the
    /// core's now (`decisions/first-contact-queue-keyed-by-claimed-device.md`); what stays here is
    /// the directory, the transcript and the one refusal the decision adds — no device, no guess.
    private func preflightWithoutSession(
        _ message: ChatMessage,
        from userId: String,
        claimed: String?,
        chat: Chat,
        isNewChat: Bool,
        in context: NSManagedObjectContext
    ) -> StreamCursorTracker.Outcome? {
        // Already processed on an earlier pass: re-ACK, and do not open from it again.
        if PersistentACKStore.shared.isProcessed(message.id, in: context) {
            Log.info("SESSION_STATE[first_message_dedup]: \(message.id.prefix(8))… from \(userId.prefix(8))… already processed — re-ACKing, no open", category: "SessionInit")
            OutboundSessionService.sendDeliveryReceipt(for: [message.id], to: userId, in: context)
            if isNewChat { context.delete(chat) }
            return .durable
        }

        // No sender certificate, so no device to key the core's queue by and no key to open with.
        // Refused rather than guessed — Android's guess (`discoverPeerDevices().first`) is the
        // defect the decision names. From current clients this is only TUI and a DEBUG build
        // with sealed sending switched off. Nothing tells the sender: a decryption error is
        // addressed to a device and sealed to its certificate key, and this message has neither.
        guard claimed != nil else {
            Log.info("SESSION_STATE[first_contact_unattributed]: \(message.id.prefix(8))… from \(userId.prefix(8))… names no device — refused", category: "SessionInit")
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "first_contact_unattributed")
            if isNewChat { context.delete(chat) }
            return .durable
        }

        // A message with no header and no session used to be answered here, before the core,
        // with an END_SESSION. It goes to the core now like any other: the core tries the
        // previous states it still holds for the device, and when none reads it sends the writer
        // a decryption error naming the state it wrote on (`decisions/sessions-renew-by-sending.md`).
        let initKind = message.initKind

        // The server says this account does not exist. No session can ever be built for it, so
        // queueing its replayed backlog buys nothing and costs the stream cursor.
        switch SessionReducer.vanishedPeerAction(markedAt: VanishedPeerStore.shared.markedAt(userId)) {
        case .proceed:
            break
        case .discard:
            Log.debug("Discarding \(initKind) from vanished peer \(userId.prefix(8))… — no session is possible", category: "MessageRouter")
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "peer_vanished")
            if isNewChat { context.delete(chat) }
            // `.durable` on purpose: nothing will revisit this message — see `VanishedPeerStore`.
            return .durable
        }
        return nil
    }

    // MARK: - Session Message Handling
    
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
            delegate?.messageRouter(self, needsUsernameUpdate: .account(userId))
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
                    ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId)
                    return true
                } else {
                    Log.info("Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Decryption errors (decisions/sessions-renew-by-sending.md, variant B)

    /// Hand a message we will not otherwise route to the core for the one answer it gives a
    /// message no state reads: a decryption error to its writer. No chat is created and nothing is
    /// saved — the message is only answered. Needs the device its certificate names; an unsealed
    /// message names none and is dropped as before.
    private func answerWithDecryptionError(_ message: ChatMessage, from userId: String, in context: NSManagedObjectContext) {
        let device = message.senderDeviceId
        guard !device.isEmpty,
              let event = buildIncomingEvent(message: message, otherUserId: userId, asDevice: device) else {
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            return
        }
        do {
            var actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "answer_unreadable")
            // After a restart the core asks whether it has seen the message before deciding.
            if let asked = OrchestratorActionPlan(actions: actions).ackCheckMessageId {
                let seen = PersistentACKStore.shared.isProcessedInCoreData(asked, in: context)
                actions = try CryptoManager.shared.handleOrchestratorEvent(
                    .ackDbResult(messageId: asked, isProcessed: seen),
                    tag: "answer_unreadable_ack"
                )
            }
            SessionActionExecutor.shared.execute(actions)
        } catch {
            Log.error("Could not answer \(message.id.prefix(8))… from \(userId.prefix(8))…: \(error)", category: "MessageRouter")
        }
        PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
    }

    /// The control frames in `actions`, as `(contentType, body)` — what the core named after
    /// reading byte 5 of the KNST frame (core 0.30).
    static func controlFrames(in actions: [CfeAction]) -> [(contentType: UInt8, body: Data)] {
        actions.compactMap { action in
            if case .controlFrameDecrypted(_, _, let contentType, let body) = action { return (contentType, body) }
            return nil
        }
    }

    /// Carry out the control frames the core named for one message from `otherUserId`, and
    /// record it processed.
    ///
    /// `otherUserId` is an **account**: the action names the peer by device, because that is what
    /// the core keeps the session under, and every handler below files by account — the receipt,
    /// the card's intake key and address, the profile. A blocked contact's frames are dropped,
    /// as its messages are (`SECURITY[block_drop]` on the body path): the ratchet has advanced,
    /// nothing is applied.
    func handleControlFrames(
        in actions: [CfeAction],
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        defer { PersistentACKStore.shared.markProcessed(messageId, senderId: otherUserId, in: context) }
        if BlockedContacts.isBlocked(otherUserId) {
            Log.info("SECURITY[block_drop]: suppressed control frame \(messageId.prefix(8))… from blocked \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }
        for frame in Self.controlFrames(in: actions) {
            handleControlFrame(contentType: frame.contentType, body: frame.body, messageId: messageId, from: otherUserId, in: context)
        }
    }

    private func handleControlFrame(
        contentType: UInt8,
        body: Data,
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        switch ContentTypeRouting.framedSideChannel(for: contentType) {
        case .deliveryReceipt:
            handleIncomingE2EDeliveryReceipt(body, messageId: messageId, from: otherUserId, in: context)
        case .contactCard:
            // The peer's card: the intake key their account accepts, so our envelopes to them
            // carry a tag instead of buying a Privacy Pass token, and their account address.
            // Filed by ACCOUNT: `sealedTag(forRecipient:)` looks the key up by account, and the
            // tag is derived over the recipient's account id — a key filed under a device id
            // would never be found, and a missing credential is a token spent, not an error.
            if let card = ContactCardPayload.read(body) {
                if let key = card.intakeKey {
                    IntakeCredentialService.shared.recordPeerIntakeKey(key, from: otherUserId)
                }
                if let address = card.accountAddress {
                    Self.pinCardAddress(address, of: otherUserId)
                }
            } else {
                Log.error("Contact card from \(otherUserId.prefix(8))… did not decode", category: "MessageRouter")
            }
        case .profile:
            // Applied only if newer than the one held — the version makes a resend or a
            // reordered queue harmless.
            if let profile = ProfileShare.read(body) {
                ProfileSharingManager.shared.apply(profile, from: otherUserId)
            } else {
                Log.error("Profile from \(otherUserId.prefix(8))… did not decode", category: "MessageRouter")
            }
        case .callSignal:
            // The core hands a call signal over as `callSignalDecrypted`, never as a control frame.
            Log.error("Call signal from \(otherUserId.prefix(8))… arrived as a control frame — dropped", category: "MessageRouter")
        case nil:
            switch contentType {
            case WireMessageKind.heartbeatContentType:
                // A liveness probe: decrypting it exercised the ratchet, which was the point.
                Log.debug("Heartbeat received from \(otherUserId.prefix(8))… — session healthy", category: "MessageRouter")
            case 25, 26:
                // Ping / ready from a build before 2026-09-27: they closed a confirm window that
                // no longer exists.
                Log.info("Session control ct=\(contentType) from \(otherUserId.prefix(8))… discarded — nothing waits for it", category: "MessageRouter")
            default:
                Log.error("Control frame ct=\(contentType) from \(otherUserId.prefix(8))… has no handler — dropped", category: "MessageRouter")
            }
        }
    }

    /// A contact's address from their card, pinned by `AccountAddressPin`. Only onto a row that
    /// exists: a sender must not be able to put a contact in our store by sending to us.
    @MainActor
    private static func pinCardAddress(_ address: Data, of accountId: String) {
        AccountAddress.pin(address, contactId: accountId, source: .card)
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
        fetch.sortDescriptors = [
            NSSortDescriptor(key: "serverOrderKey", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        fetch.fetchLimit = 1
        guard let last = try? context.fetch(fetch).first else { return false }
        return last.fromUserId == "SYSTEM" && last.legacyBody == text
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

        // A per-device copy travels under `<baseId>-fd-<tag>`, so the envelope id differs from
        // device to device while the message is one message. The KNST frame carries the sender's
        // own id and is preferred anyway; the fallback strips the suffix so a transcript row has
        // the same id on every device of the account. Without it a reaction sent from one device
        // would reference an id its siblings never stored.
        let envelopeId = DeviceCopyWireId.baseId(of: messageData.id) ?? messageData.id
        var canonicalId = (e2eMessageId ?? envelopeId).lowercased()
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id ==[c] %@", canonicalId)
        fetchRequest.fetchLimit = 1

        // Check if message already exists (from background fetch, retry redelivery, …)
        if let existingMessage = try context.fetch(fetchRequest).first {
            if existingMessage.fromUserId == messageData.from {
                var changed = false
                if let serverOrderKey = messageData.serverOrderKey,
                   existingMessage.serverOrderKey != serverOrderKey {
                    existingMessage.serverOrderKey = serverOrderKey
                    changed = true
                }
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
                    changed = true
                }
                if changed {
                    try context.saveOrThrow(category: "MessageRouter")
                    Log.debug("Updated message content/order", category: "MessageRouter")
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
        message.serverOrderKey = messageData.serverOrderKey
            ?? ServerMessageOrder.local(timestamp: message.timestamp, messageId: canonicalId)
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
            message.replyQuote = ReplyPreviewPayload.receiving(
                textPreview: qm.hasTextPreview ? qm.textPreview : nil,
                mediaType: qm.hasMediaType ? qm.mediaType : nil
            )?.storedContent
        } else if !messageData.replyToMessageId.isEmpty {
            message.replyToMessageId = messageData.replyToMessageId.lowercased()
            let replyFetch = Message.fetchRequest()
            replyFetch.predicate = NSPredicate(format: "id ==[c] %@", messageData.replyToMessageId)
            replyFetch.fetchLimit = 1
            do {
                if let replyMsg = try context.fetch(replyFetch).first {
                    message.replyQuote = ReplyPreviewPayload.projecting(
                        originalContent: replyMsg.legacyBody
                    )?.storedContent
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

        // A copy addressed to one of our *other* devices. The server does not route per device —
        // `messaging-service/src/core.rs` fans every envelope out to all of the recipient's
        // per-device streams — so on a three-device account each device receives the two copies
        // meant for the other two and can decrypt neither.
        //
        // The target is on the wire in the id suffix the sender writes, `-ss-<tag>`, so recognising
        // a foreign copy costs one X25519 per own device. Without it every foreign copy walks the
        // whole candidate list, fails each decrypt, and — with messageNumber 0 — takes the recovery
        // path into a bundle fetch, for a message that was never ours to read.
        //
        // The tag is a MAC under a secret only the two devices share, not the device id it used to
        // be; see SenderSyncDeviceTag for what the readable form gave the relay.
        if DeviceCopyWireId.read(
            wireId: message.id,
            ourDeviceId: AuthSessionManager.shared.currentDeviceId,
            tagger: SenderSyncDeviceTag.Tagger.current,
            peerIdentityKeys: MultiDeviceSendCoordinator.shared.senderSyncPeerIdentityKeys(myUserId: currentUserId),
            // Own replicas: the cache holds every sibling we know of, and the verdict does not
            // consult this flag for that audience — passed for the shape, not for the decision.
            peerDeviceSetIsComplete: true
        ).verdict == .foreign {
            Log.debug(
                "SENDER_SYNC: \(message.id) is addressed to another of our devices — skipping",
                category: "MessageRouter"
            )
            PersistentACKStore.shared.markProcessed(message.id, senderId: message.from, in: context)
            return
        }

        // Which of our own devices sent this is settled by decryption, not by a field: the sender
        // device selects the Double Ratchet session, so it is needed *before* the plaintext exists
        // and cannot travel inside it. We try our own-device sessions; the one that opens the
        // message is the answer, and it is a cryptographic one rather than a claim.
        //
        // `message.senderDeviceId` was always empty here until the unseal boundary began recovering
        // it from the sender certificate (2026-09-06); before that the old code took the
        // `message.from` branch, looked up a session that is the *primary* session with ourselves,
        // and got nowhere. Since 2026-09-27 every copy carries its certificate (`OwnDeviceCopy`).
        let candidates = senderSyncSessionCandidates(myUserId: currentUserId, message: message)
        guard let opened = openSenderSync(message, candidates: candidates) else {
            handleUnopenedSenderSync(message, candidates: candidates, in: context)
            return
        }

        routeOpenedSenderSync(opened.plaintext, original: message, myUserId: currentUserId, in: context)
    }

    /// Reassemble → strip the routing header → save. The one implementation of what happens to a
    /// SENDER_SYNC once it is open, so the session-already-existed path and the
    /// session-established-just-now path cannot come to differ.
    ///
    /// `assemble` stops before content decoding on purpose: the header has to come off in between,
    /// and it is only present once in a reassembled multi-chunk stream — see `SenderSyncRouting`.
    private func routeOpenedSenderSync(
        _ plaintext: Data,
        original: ChatMessage,
        myUserId: String,
        in context: NSManagedObjectContext
    ) {
        switch chunkReassembler.assemble(data: plaintext, envelopeId: original.id) {
        case .incomplete:
            Log.debug("SENDER_SYNC: chunk incomplete — waiting for more", category: "MessageRouter")
        case .invalid(let reason):
            Log.error("SENDER_SYNC: framing invalid for \(original.id): \(reason)", category: "MessageRouter")
        case .notFramed(let raw):
            saveSenderSyncFromRouted(raw, original: original, myUserId: myUserId, in: context)
        case .complete(let assembled, let e2eMessageId):
            saveSenderSyncFromRouted(
                assembled,
                original: original,
                myUserId: myUserId,
                e2eMessageId: e2eMessageId,
                in: context
            )
        }
    }

    /// Strip the routing header, then hand the content to the ordinary decoder.
    private func saveSenderSyncFromRouted(
        _ assembled: Data,
        original: ChatMessage,
        myUserId: String,
        e2eMessageId: String? = nil,
        in context: NSManagedObjectContext
    ) {
        guard let (routing, content) = SenderSyncRouting.decode(prefixOf: assembled) else {
            // No header: the sender is running a build from before this existed, and nothing in
            // the delivery says which conversation the copy belongs to. Same outcome as every
            // SENDER_SYNC before this change, and the same message.
            legacySenderSyncUnroutable(original)
            return
        }
        guard routing.partnerUserId != myUserId else {
            Log.error(
                "SENDER_SYNC: routing header names ourselves as the partner for \(original.id) — dropping",
                category: "MessageRouter"
            )
            return
        }
        saveSenderSyncMessage(
            content,
            original: original,
            partnerUserId: routing.partnerUserId,
            e2eMessageId: e2eMessageId,
            in: context
        )
    }

    /// A sync we could open but cannot place: the sender did not send a routing header.
    ///
    /// This was every SENDER_SYNC before 2026-08-17. `buildEnvelope` sets `conversationID` and
    /// `senderDevice` on every non-sealed envelope and SENDER_SYNC is never sealed, but the server
    /// blanks both on delivery **on purpose** (`messaging-service/src/envelope.rs`:
    /// `sender_device: None`, and "conversation_id is intentionally empty: it is server-visible
    /// metadata and must not carry E2E semantics"). Observed 2026-08-05, one message id on both
    /// sides of a single account:
    ///
    ///     sent      1aa6abac…-ss-b3ed60ab  conversationId = direct:0a1c609f…:ea134859…
    ///     received  conversationId = ''    senderDevice = ''
    ///
    /// The message routed on metadata the server is designed never to deliver — a design
    /// contradiction rather than a relay bug. It is now carried inside the ciphertext, so this path
    /// means only "the other device is on an older build".
    private func legacySenderSyncUnroutable(_ message: ChatMessage) {
        Log.error(
            "SENDER_SYNC: no routing header in \(message.id) — the sending device predates the header, and conversationId is blanked by the server by design, so this copy cannot be placed in a conversation.",
            category: "MessageRouter"
        )
        PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_routing_header")
    }

    /// Own-device sessions to try, most likely first — device ids only.
    ///
    /// `message.from` — our own account — led this list until 2026-09-27, for a sibling whose
    /// copy named no device. Every copy names one now (`OwnDeviceCopy` carries the certificate),
    /// and an account id below the seam only ever logged `hasSession(for:) was handed … an
    /// account id`.
    private func senderSyncSessionCandidates(myUserId: String, message: ChatMessage) -> [String] {
        var keys: [String] = []
        if !message.senderDeviceId.isEmpty {
            // The sibling that wrote this copy, from its certificate. Free to try, and it
            // short-circuits the loop when present.
            keys.append(message.senderDeviceId)
        }
        // Siblings, not every own device: this one cannot have sent us a SENDER_SYNC.
        for deviceId in MultiDeviceSendCoordinator.shared.knownSiblingDeviceIds(myUserId: myUserId) {
            let key = deviceId
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// Try each candidate session until one opens the message.
    ///
    /// A failed Double Ratchet decrypt does not advance the ratchet, so trying the wrong session
    /// costs nothing but the attempt — and there are as many attempts as the account has devices.
    private func openSenderSync(
        _ message: ChatMessage,
        candidates: [String]
    ) -> (plaintext: Data, contactId: String)? {
        for contactId in candidates where CryptoManager.shared.hasSession(for: contactId) {
            // `claimedByThisHandler`: `routeIncomingMessage` marked this id processed before
            // calling us, so the duplicate guard inside `decryptMessage` would refuse every
            // candidate on the strength of our own claim — which is what dropped every
            // SENDER_SYNC after the first on a multi-device account until 2026-08-27.
            if let result = try? CryptoManager.shared.decryptMessage(
                message, contactIdOverride: contactId, claimedByThisHandler: true
            ) {
                return (result.plaintext, contactId)
            }
        }
        return nil
    }

    /// No candidate session opened it. A message carrying the handshake header is the one
    /// recoverable case: the sibling opened a new state — or its first — and this opens it.
    private func handleUnopenedSenderSync(
        _ message: ChatMessage,
        candidates: [String],
        in context: NSManagedObjectContext
    ) {
        let kind = message.initKind
        guard kind == .handshake else {
            Log.error(
                "SENDER_SYNC: no own-device session opened \(message.id) and it carries no handshake header (messageNumber=\(message.messageNumber)) — dropping",
                category: "MessageRouter"
            )
            // Counted, like the branch below. This is the *more common* way to be unroutable —
            // it is what a device does with every sync after losing the session, and until
            // 2026-08-30 losing it was routine, because the restore read the chat list and an
            // own-device session has no chat. The release gate is `sender_sync_unroutable` at
            // zero on a three-device run, and the commonest path to non-zero was not counted.
            PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_session_and_not_first")
            return
        }
        guard let myUserId = AuthSessionManager.shared.currentUserId else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }

            // A device that linked and has not yet sent anything knows of no siblings: the
            // own-device cache had one filler and it was the send path. So the candidate list held
            // no device id, and the loop below skipped it — silently, which is how this went
            // unnoticed until the two-sim stand showed a freshly linked device dropping both
            // copies without a line in the log.
            var candidates = candidates
            if SenderSyncRecovery.needsOwnDeviceRefresh(candidates: candidates) {
                await MultiDeviceSendCoordinator.shared.refreshOwnDevices(myUserId: myUserId)
                candidates = self.senderSyncSessionCandidates(myUserId: myUserId, message: message)
                // The refresh may also have produced a session-bearing candidate that already
                // works; retry the cheap path before reaching for bundles.
                if let opened = self.openSenderSync(message, candidates: candidates) {
                    self.routeOpenedSenderSync(
                        opened.plaintext, original: message, myUserId: myUserId, in: context
                    )
                    return
                }
            }

            // No session opened it and it carries the header, so the sibling opened a new state
            // (or its first) with us: it opens under the device its sender certificate names, with the key the certificate names — one
            // attempt, nothing fetched (`decisions/first-message-opens-without-the-server.md`).
            // Until 2026-09-27 this walked the own-device candidates and fetched a bundle for
            // each, because the copy said nothing about which sibling had written it.
            if let certificate = message.senderCertificate, certificate.userId == myUserId {
                self.openSenderSync(firstMessage: message, myUserId: myUserId, in: context)
                if CryptoManager.shared.hasSession(for: certificate.deviceId) { return }
            }

            // Reaching here means the copy is unrecoverable. Say so: the previous version ended
            // exactly here having done nothing, and an unroutable transcript copy that leaves no
            // trace is indistinguishable from one that never arrived.
            Log.error(
                "SENDER_SYNC: \(message.id.prefix(8))… opened under no own-device session and none could be established (\(candidates.count) candidate(s)) — dropping",
                category: "MessageRouter"
            )
            PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_own_device_session")
        }
    }

    // `extractPartnerUserId(from:myUserId:)` was removed 2026-08-17 with its only caller. It read
    // the partner out of `Envelope.conversation_id`, which the server blanks on delivery by
    // design, so it returned "" for every SENDER_SYNC ever received. The partner now travels
    // inside the ciphertext — see `SenderSyncRouting`.

    /// Save a decrypted SENDER_SYNC message as an outgoing bubble.
    ///
    /// Wire payload is the same binary path as a normal receive (KNST → MessageContent).
    /// Local store uses CTM1 `storagePayload` when the reassembler provides it (C1c).
    /// - Parameters:
    ///   - content: the message content with its routing header already removed, and already
    ///     reassembled — the caller had to split those two steps to reach the header, so this must
    ///     not run the framing again.
    ///   - e2eMessageId: the sender's message id from the KNST header, carried over from `assemble`.
    private func saveSenderSyncMessage(
        _ content: Data,
        original: ChatMessage,
        partnerUserId: String,
        e2eMessageId: String?,
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

        switch ChunkedMessageReassembler.shared.decodeAssembled(content, e2eMessageId: e2eMessageId) {
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
        case .reaction(let targetMessageID, let emoji, let action, let timestampMs):
            let decision = ReactionStore.applyIncoming(
                targetMessageId: targetMessageID,
                reactorUserId: original.from,
                actionRawValue: action.rawValue,
                emoji: emoji,
                payloadTimestampMs: timestampMs,
                fallbackTimestampMs: ReactionStore.envelopeTimestampMs(original.timestamp),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                in: context
            )
            Log.info(
                "SENDER_SYNC: reaction on \(targetMessageID.prefix(8))… \(decision) — not a chat row",
                category: "MessageRouter"
            )
            return
        case .incomplete:
            // Unreachable: reassembly finished before the caller stripped the routing header.
            // Kept because the result type is shared with `process`.
            Log.error("SENDER_SYNC: decoder reported incomplete on assembled bytes", category: "MessageRouter")
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
            if let existing = try context.fetch(fetch).first {
                if let serverOrderKey = original.serverOrderKey,
                   existing.serverOrderKey != serverOrderKey {
                    existing.serverOrderKey = serverOrderKey
                    context.saveAndLog()
                }
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
        msg.serverOrderKey = original.serverOrderKey
            ?? ServerMessageOrder.local(timestamp: msg.timestamp, messageId: rowId)
        msg.isSentByMe = true
        msg.deliveryStatus = .sent
        msg.retryCount = 0
        msg.chat = chat

        msg.applyStoredEncryption(plaintextData: storagePayload, contactId: partnerUserId)
        if let mediaAlbum {
            MediaWireCodec.receiveAlbum(mediaAlbum, for: rowId)
        }

        chat.applyPreview(text: previewText, timestamp: msg.timestamp)
        context.saveAndLog()

        if !original.senderDeviceId.isEmpty {
            CryptoManager.shared.saveSessionToKeychain(
                forDevice: original.senderDeviceId
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

    /// Open the session a sibling's SENDER_SYNC arrived on, from the copy itself, then route it.
    private func openSenderSync(
        firstMessage message: ChatMessage,
        myUserId: String,
        in context: NSManagedObjectContext
    ) {
        do {
            let opened = try CryptoManager.shared.openReceiving(singleMessage: message)
            routeOpenedSenderSync(opened.plaintext, original: message, myUserId: myUserId, in: context)

            // Replenish any OTPKs consumed during this session init
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
        } catch {
            Log.error("SENDER_SYNC: opening \(message.id.prefix(8))… failed: \(error)", category: "MessageRouter")
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
    /// Whether `userId` is a blocked contact. One indexed read of saved state; safe on the
    /// incoming-message hot path. Empty/unknown ids → not blocked (fail-open: a block is a
    /// user-initiated suppression, not a boundary whose lookup failure should drop legitimate
    /// traffic).
    static func isBlocked(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return (try? LocalRepositories.contacts.isBlocked(userId)) ?? false
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
