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
            CryptoManager.shared.markAckProcessedInOrchestrator(messageId: messageId)

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

        // ── Async DB check ────────────────────────────────────────
        case .checkAckInDb(let messageId):
            Task { @MainActor in
                let isProcessed = await PersistentACKStore.shared.isProcessedInCoreData(messageId: messageId)
                let result = CfeIncomingEvent.ackDbResult(messageId: messageId, isProcessed: isProcessed)
                do {
                    _ = try CryptoManager.shared.handleOrchestratorEvent(result, tag: "ack_db_result_async")
                } catch {
                    Log.error("ACK DB result follow-up failed for \(messageId.prefix(8))…: \(error)", category: "SessionActionExecutor")
                }
            }

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
