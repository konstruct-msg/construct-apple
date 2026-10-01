import Foundation

/// Executes `CfeAction` results returned by the Rust orchestrator.
///
/// **Design principle**: the orchestrator decides *what* should happen; this
/// component executes *how* it happens on the platform side (Keychain, gRPC,
/// timers, Core Data, notifications).
///
/// **Wired call sites**:
/// - `MessageRouter.executeRustActions` — dispatch on the incoming-message hot path
/// - `OutboundSessionService.executeRustTimerActions` — fired by Rust timers
/// - `executeOffRouter` — every other event's answer; logs a router-bound action it cannot run
///
/// State-bound actions (`.messageDecrypted`, `.openReceiving`) still execute
/// inline in `MessageRouter` because they
/// depend on the router's `chunkReassembler`, core envelopes and `delegate`. The
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

    /// Runs `.openSession`: open a new session with this **device** as INITIATOR over the one held.
    ///
    /// Supplied by `SessionCoordinator`, the only place that can read the device id back to the
    /// account a bundle is fetched for. Nothing is announced: the handshake header rides on the
    /// next message to the device (`decisions/sessions-renew-by-sending.md`).
    var onOpenSession: ((String) -> Void)?

    /// Runs `.sessionRetired`: the peer could not read our current state with this **device**, the
    /// core retired it, and the next send opens a new one — without a one-time prekey when the
    /// flag says so. Supplied by `SessionCoordinator`, which owns how the next open is made.
    var onSessionRetired: ((_ device: String, _ withoutOneTimePrekey: Bool) -> Void)?

    /// Runs `.resendMessage`: send the named message to this **device** again. Supplied by
    /// `SessionCoordinator`, which owns the outgoing messages and their resend path.
    var onResendMessage: ((_ device: String, _ messageId: String) -> Void)?

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

    /// Execute the core's answer to an event that did **not** come through `MessageRouter`.
    ///
    /// Every answer the core gives has to reach here; an event whose result is dropped with
    /// `_ = try?` is a producer with no consumer. That is how the `open_confirm:` alarm went
    /// unarmed from 2026-09-23 until the alarm itself was removed on 2026-09-27: the call site
    /// kept throwing the core's answer away.
    ///
    /// The router-bound actions still `break` in `execute`, because on the router's own paths the
    /// router carries them out after it returns. Off those paths nobody does, so each one that
    /// arrives here is logged as dropped instead of disappearing. `consumed` names the ones this
    /// caller does carry out itself.
    func executeOffRouter(
        _ actions: [CfeAction],
        site: String,
        consumed: (CfeAction) -> Bool = { _ in false }
    ) {
        execute(actions)
        for action in actions where !consumed(action) {
            guard let name = Self.routerBoundName(action) else { continue }
            Log.error(
                "\(name) reached SessionActionExecutor from \(site) — only MessageRouter carries it out, so it is dropped here",
                category: "SessionActionExecutor"
            )
        }
    }

    /// The actions only `MessageRouter` can carry out, by name — never the payload, which for a
    /// decrypted message is plaintext.
    private static func routerBoundName(_ action: CfeAction) -> String? {
        switch action {
        case .openReceiving: return "openReceiving"
        case .messageDecrypted: return "messageDecrypted"
        default: return nil
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
        case .archiveSession:
            break
        case .markMessageDelivered:
            break
        case .duplicateDropped:
            // A routing verdict; MessageRouter records the message as processed and moves the
            // cursor past it. Off the router (a drain) it concerns a message already handled.
            break
        case .sendEncryptedMessage:
            break
        case .sendReceipt:
            break
        case .notifySessionCreated:
            break

        // ── Storage (currently in OutboundSessionService) ─────────
        case .saveToSecureStore:
            OutboundSessionService.shared.executeStorageActions([action])

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
        case .openReceiving:
            // The router keeps the envelope and asks the coordinator for the open.
            break

        // ── Decryption errors (decisions/sessions-renew-by-sending.md, variant B) ──
        case .sendDecryptionError(let contactId, let messageId, let payload, let enveloped):
            // We could not read `messageId`; the core built the error and sealed it to the writer.
            // Sent from here because it is the answer to a routed message *and* to a failed open,
            // and both answers pass through this executor. The message itself is recorded by the
            // router (or was given up by the open); nothing here decides anything.
            Task {
                do {
                    _ = try await MessagingServiceClient.shared.sendDecryptionError(
                        toDevice: contactId,
                        payload: payload,
                        enveloped: enveloped
                    )
                    Log.info(
                        "SESSION_STATE[decryption_error_sent]: \(contactId.prefix(8))… could not be read (\(messageId.prefix(8))…)",
                        category: "SessionInit"
                    )
                } catch {
                    Log.error(
                        "DECRYPTION_ERROR to \(contactId.prefix(8))… not sent: \(error.localizedDescription)",
                        category: "SessionInit"
                    )
                }
            }

        case .sessionRetired(let contactId, let withoutOneTimePrekey):
            guard let onSessionRetired else {
                Log.error("SessionRetired for \(contactId.prefix(8))… with no consumer wired", category: "SessionActionExecutor")
                return
            }
            onSessionRetired(contactId, withoutOneTimePrekey)

        case .resendMessage(let contactId, let messageId):
            guard let onResendMessage else {
                Log.error("ResendMessage \(messageId.prefix(8))… with no consumer wired — it is not resent", category: "SessionActionExecutor")
                return
            }
            onResendMessage(contactId, messageId)

        case .openSession(let contactId):
            // The core asked for the open (the PQXDH v2 upgrade sweep). Nothing here decides
            // *whether* — a guard at this point would be a second decider.
            guard let onOpenSession else {
                Log.error(
                    "OpenSession for \(contactId.prefix(8))… with no consumer wired — the re-init is lost",
                    category: "SessionActionExecutor"
                )
                return
            }
            onOpenSession(contactId)

        case .messageQueuedPendingInit(let contactId, let queuedCount):
            // Held inside the core behind an in-flight init and drained on SessionInitCompleted.
            // Nothing is lost — which is the point of it having a name.
            Log.info(
                "Message queued in core behind session init for \(contactId.prefix(8))… (\(queuedCount) waiting)",
                category: "SessionActionExecutor"
            )

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
        case .notifyError(let code, let msg) where code == OrchestratorActionPlan.decryptFailedCode:
            // The cause of a refusal the core is already answering with a DECRYPTION_ERROR —
            // a message from a deleted chat or a reset state lands here every time, and the
            // writer opens a new state. Logged at ERROR it read as a fault on every such delivery.
            Log.info("Unreadable message, answered [\(code)]: \(msg)", category: "SessionActionExecutor")
        case .notifyError(let code, let msg):
            Log.error("Rust orchestrator error [\(code)]: \(msg)", category: "SessionActionExecutor")
        }
    }
}
