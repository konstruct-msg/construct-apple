/// Executes `CfeAction` results returned by the Rust orchestrator.
///
/// **Design principle**: the orchestrator decides *what* should happen; this
/// component executes *how* it happens on the platform side (Keychain, gRPC,
/// timers, Core Data, notifications).
///
/// **Wired call sites**:
/// - `MessageRouter.executeRustActions` — dispatch on the incoming-message hot path
/// - `OutboundSessionService.executeRustTimerActions` — fired by Rust timers
///
/// State-bound actions (`.messageDecrypted`, `.sessionHealNeeded`, `.sendEndSession`,
/// `.fetchPublicKeyBundle`) still execute inline in `MessageRouter` because they
/// depend on the router's `chunkReassembler`, `pendingQueue`, and `delegate`. The
/// executor `break`s on these cases so the router can handle them after the
/// `SessionActionExecutor.shared.execute(actions)` call returns.
///
/// **Exhaustiveness**: the `switch` has **no `default:` case**. When Rust adds
/// a new `CfeAction`, UniFFI bindings regenerate and this file will fail to
/// compile until the new case is handled explicitly. This is intentional — we
/// want compile-time lockstep, not silent runtime `fatalError`.
@MainActor
final class SessionActionExecutor {
    static let shared = SessionActionExecutor()
    private init() {}

    /// Execute a batch of actions returned by `CryptoManager.handleOrchestratorEvent`.
    ///
    /// Stateless actions execute here; state-bound actions (`.messageDecrypted`
    /// et al.) are `break`-stubbed and must be handled by the caller after this
    /// returns. See the class doc-comment for the rationale.
    func execute(_ actions: [CfeAction]) {
        for action in actions {
            executeOne(action)
        }
    }

    // MARK: - Single action dispatch

    private func executeOne(_ action: CfeAction) {
        switch action {
        // ── Already handled by higher-level callers (no-op here) ─
        // These are consumed by the MessageRouter / session-init path
        // and should not be re-executed by the generic executor.
        case .decryptMessage:
            break
        case .encryptMessage:
            break
        case .initSession:
            break
        // Needs the KEM ciphertext decapsulated with the right Kyber secret and applied at a
        // precise point in the ratchet, so it is owned by the two paths that hold that context:
        // `MessageRouter.applyIncomingPqContribution` (carrier on an existing session) and
        // `CryptoSessionInitializationService` (RESPONDER init). Both go through
        // `PQCKeyManager.applyIncomingContribution`. This no-op used to be the whole story on
        // the router path — the contribution was dropped and the peer's ratchet drifted.
        case .applyPqContribution:
            break
        case .archiveSession:
            break
        case .loadSessionFromSecureStore:
            break
        case .markMessageDelivered:
            break
        case .sendEncryptedMessage:
            break
        case .sendReceipt:
            break
        case .notifySessionCreated:
            break

        // ── Storage (currently in OutboundSessionService) ─────────
        case .saveSessionToSecureStore:
            OutboundSessionService.shared.executeStorageActions([action])

        case .sessionTerminated(let contactId, let archiveBytes):
            CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: archiveBytes)
            CryptoManager.shared.saveOrchestratorStateCFE()

        case .persistMessage:
            // Rust tells us to persist a message it decrypted — currently
            // handled inline in MessageRouter.handleResolvedMessage.
            break  // scaffold

        // ── ACK ───────────────────────────────────────────────────
        case .persistAck(let messageId, _):
            // The core means "platform must durable-persist this record" (`ack_store.rs:109`).
            // The L2 write itself belongs to `MessageRouter`'s terminal paths, which know whether
            // the message was saved, handled or given up; this handler cannot know that yet, and
            // writing here unconditionally would mark work that has not happened.
            //
            // So it records the obligation and the router settles it. Nothing else about this
            // action was doing anything: `markAckProcessedInOrchestrator` was provably inert
            // (`mark_processed` inserts into the cache *before* emitting the action, so the second
            // call short-circuits at `ack_store.rs:112`), and the metric fired once per decrypted
            // message — a counter of traffic, not of failure.
            //
            // Superseded reasoning, kept because it read like proof and no longer is: the old
            // comment said L2 must not be written for multi-chunk `.incomplete` or a restart would
            // find "processed" with an empty reassembler. That was true until `PendingReassemblyStore`
            // (2026-08-03) made the chunks durable; `MessageRouter` now marks intermediate envelopes
            // at the durable put, deliberately. See decisions/durable-chunk-reassembly.
            PersistentACKStore.shared.expectDurableWrite(messageId)

        case .pruneAckStore:
            // Periodic prune — currently a no-op on Swift side
            break

        // ── Timers ────────────────────────────────────────────────
        case .scheduleTimer(let timerId, let delayMs):
            OutboundSessionService.shared.scheduleRustTimer(timerId: timerId, delayMs: delayMs)

        case .cancelTimer(let timerId):
            OutboundSessionService.shared.cancelRustTimer(timerId: timerId)

        // ── Network / transport ───────────────────────────────────
        case .sendHeartbeat(let contactId):
            Task { await OutboundSessionService.shared.sendSessionHeartbeat(to: contactId) }

        case .notifyLinkedDevicesOfSessionReset(let contactId):
            Task { await MultiDeviceSendCoordinator.shared.broadcastSessionReset(contactId: contactId) }

        case .fetchPublicKeyBundle:
            // Requires MessageRouter.pendingQueue + bundle fetch path
            break  // scaffold

        // ── Healing / END_SESSION (need MessageRouter state) ──────
        case .sessionHealNeeded:
            // Requires MessageRouter.handleRustHealDecision
            break  // scaffold

        case .sendEndSession:
            // Requires MessageRouter delegate callbacks
            break  // scaffold

        case .healSuppressed(let contactId, let retryAfterMs):
            Log.debug("Heal suppressed for \(contactId.prefix(8))… retry in \(retryAfterMs)ms", category: "SessionActionExecutor")

        // ── ACK DB check: NOT ours to answer ──────────────────────
        case .checkAckInDb(let messageId):
            // `MessageRouter` owns this round-trip, synchronously, because the answer decides how
            // the message routes and the router is the only place that can act on the result.
            //
            // This case used to answer it too, from a detached Task, and discard the verdict
            // (`_ = try …`). Both halves are load-bearing failures. The core removes the buffered
            // message in `resume_after_ack_check` (`message_router.rs:262`), so whichever answer
            // lands first consumes it and the other gets `RoutingDecision::Error` — and if the
            // async one won, the real routing decision was the thing thrown away, leaving a
            // message decrypted by nobody.
            //
            // It never fired in practice (zero occurrences across four device logs, no
            // ROUTING_ERROR either), but only because of which action lists happen to reach this
            // executor — nothing enforced it. Now the invariant is stated instead of assumed: if
            // this ever runs, the list came from a path that must be routed through the router,
            // and the ERROR says so rather than the message quietly going missing.
            Log.error(
                "checkAckInDb reached SessionActionExecutor for \(messageId.prefix(8))… — this round-trip belongs to MessageRouter; NOT answering here, the message will not route",
                category: "SessionActionExecutor"
            )
            PerformanceMetrics.shared.record(.ackCheckOutsideRouter, label: "session_action_executor")

        // ── Decryption result (needs chunk reassembler + save) ───
        case .messageDecrypted:
            // Requires MessageRouter.chunkReassembler + save path
            break  // scaffold

        case .callSignalDecrypted(let contactId, _, let protoBytes):
            if let signal = CallManager.decodeSignalProto(from: protoBytes) {
                CallManager.shared.handleCallSignalProto(from: contactId, signal: signal)
            }

        // ── Informational ─────────────────────────────────────────
        case .notifyNewMessage:
            break

        // ── Error reporting ───────────────────────────────────────
        case .notifyError(let code, let msg):
            Log.error("Rust orchestrator error [\(code)]: \(msg)", category: "SessionActionExecutor")
        }
    }
}
