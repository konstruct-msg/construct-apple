//
//  OutboundSessionService.swift
//  Construct Messenger
//
//  Handles all outbound session operations that go through the Rust orchestrator:
//  message encryption, session control, heartbeats, E2E receipts, storage action
//  execution, and Rust timer scheduling.
//
//  Extracted from MessageRouter so these operations are independently testable
//  and callable without touching MessageRouter's incoming-message state.
//

import CoreData
import Foundation
import SwiftProtobuf

/// Thrown by `encryptOutgoing` when the sending-chain advance for a just-encrypted message could
/// not be durably persisted. Fail-closed: the caller MUST treat this as a retryable send failure
/// (queue + retry), never as a delivered message. Emitting the ciphertext anyway would let the peer
/// observe a ratchet advance that a later crash + stale reload rolls back → message-number reuse →
/// a mid-session desync that healing (msgNum==0 only) never recovers.
/// See decisions/sender-state-durability-before-send.md.
enum SessionStatePersistError: Error {
    case sendStateNotDurable
}

@MainActor
final class OutboundSessionService {

    static let shared = OutboundSessionService()

    // MARK: - Rust Timer Support

    private var rustTimers: [String: Task<Void, Never>] = [:]
    private let rustTimersLock = NSLock()

    /// Timer-fired `sendEndSession` — the incoming-message path handles this action in
    /// `MessageRouter`, but a cooldown timer fires off that path. SessionCoordinator
    /// registers the same `needsEndSession` consumer so the owed teardown actually goes out.
    var onTimerSendEndSession: ((String) -> Void)?

    /// Schedules (or reschedules) a Rust-requested timer. Fires `timerFired` after `delayMs`.
    func scheduleRustTimer(timerId: String, delayMs: UInt64) {
        cancelRustTimer(timerId: timerId)
        let task = Task { @MainActor [weak self] in
            let ns = UInt64(delayMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, let self else { return }
            let event = CfeIncomingEvent.timerFired(timerId: timerId)
            if let actions = try? CryptoManager.shared.handleOrchestratorEvent(event, tag: "rust_timer"),
               !actions.isEmpty {
                self.executeRustTimerActions(actions)
            }
            _ = self.rustTimersLock.withLock { self.rustTimers.removeValue(forKey: timerId) }
        }
        rustTimersLock.withLock { rustTimers[timerId] = task }
        Log.debug("Rust timer scheduled: \(timerId) in \(delayMs)ms", category: "OutboundSession")
    }

    /// Cancels a pending Rust-requested timer.
    func cancelRustTimer(timerId: String) {
        rustTimersLock.withLock {
            if let existing = rustTimers.removeValue(forKey: timerId) {
                existing.cancel()
                Log.debug("Rust timer cancelled: \(timerId)", category: "OutboundSession")
            }
        }
    }

    private func executeRustTimerActions(_ actions: [CfeAction]) {
        // Delegate to the centralised executor — it handles scheduleTimer/cancelTimer,
        // notifyError, saveToSecureStore, sessionTerminated, and the rest of the
        // CfeAction surface exhaustively. See SessionActionExecutor.
        SessionActionExecutor.shared.execute(actions)

        // Router-owned actions the executor deliberately no-ops: on the incoming-message
        // path MessageRouter consumes them after `execute` returns. A timer fire never
        // reaches that loop, so without this the cooldown-expired `sendEndSession` the
        // core emits (`orchestrator.rs` handle_timer_fired) has no consumer.
        for action in actions {
            if case .sendEndSession(let contactId) = action {
                onTimerSendEndSession?(contactId)
            }
        }
    }

    // MARK: - Outgoing Encryption

    /// Encrypts a plaintext message through the Rust orchestrator (single DR source of truth).
    ///
    /// Returns binary WirePayload ready for `encryptedPayload` in the gRPC `SendMessage` call.
    /// Persists updated DR session state as a side-effect.
    ///
    /// - Parameters:
    ///   - plaintext: Serialised plaintext bytes (protobuf, binary KNST frame, or UTF-8).
    ///   - messageId: Unique message UUID for ACK tracking.
    ///   - recipientId: Contact user ID.
    ///   - contentType: Proto ContentType raw value (0 = regular message, default).
    func encryptOutgoing(
        plaintext: Data,
        messageId: String,
        recipientId: String,
        contentType: UInt8 = 0
    ) throws -> Data {
        let event = CfeIncomingEvent.outgoingMessage(
            contactId: recipientId,
            messageId: messageId,
            plaintext: plaintext,
            contentType: contentType
        )
        let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "outgoing_message")

        // Fail-closed durability: the encrypt above already advanced the in-memory sending chain.
        // Only release the ciphertext once that advance is durably persisted. If the session-state
        // save failed, refuse — otherwise the peer would see an advance that a crash + stale reload
        // rolls back, and the reloaded chain reuses this message number → mid-session desync that
        // healing does not cover. Throwing keeps the message queued; retry re-encrypts safely
        // because nothing was sent. See decisions/sender-state-durability-before-send.md.
        let sendStateDurable = executeStorageActions(actions)
        guard sendStateDurable else {
            Log.error("encryptOutgoing: session-state persist FAILED for \(recipientId.prefix(8))… (msg \(messageId.prefix(8))…) — refusing to release ciphertext (prevents ratchet number reuse)", category: "OutboundSession")
            throw SessionStatePersistError.sendStateNotDurable
        }

        for action in actions {
            if case .sendEncryptedMessage(let to, let payload, _, _) = action, to == recipientId {
                return Data(payload)
            }
        }
        throw NSError(
            domain: "OutboundSessionService",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "Orchestrator returned no SendEncryptedMessage for \(recipientId.prefix(8))…"]
        )
    }

    /// Encrypts a session control message (ping, END_SESSION, sessionResetInit, etc.).
    ///
    /// These are deliberately sent WITHOUT stealth (even if global stealth is enabled).
    /// They are protocol-level, not user content. See stealth scope decisions.
    func encryptSessionControl(
        plaintext: String,
        messageId: String,
        recipientId: String
    ) throws -> Data {
        try encryptSessionControl(
            payload: Data(plaintext.utf8),
            messageId: messageId,
            recipientId: recipientId
        )
    }

    /// Binary variant for typed session-control payloads (serialized `SessionControl`, built by
    /// `SessionControlCodec.encodePayload`). The control payload stays `Data` end-to-end — no
    /// stringification across the crypto boundary.
    ///
    /// Pass `frameAs` for the ops whose type must be hidden from the server (ping 25, ready 26):
    /// the payload is wrapped in a KNST frame carrying the type in byte 5, inside the ciphertext,
    /// and `SealedInner.content_type` is left UNSPECIFIED by the caller.
    ///
    /// **END_SESSION (21) and SESSION_RESET_INIT (24) must NOT be framed.** Both have to be
    /// recognised *before* decryption — END_SESSION carries no ciphertext at all, and an SRI is
    /// wire-identical to an ordinary X3DH carrier, so the receiver cannot tell them apart from the
    /// body alone. They keep their pre-decrypt hint on `SealedInner`; that residue is the whole
    /// reason the field survives. See decisions/sealed-content-type-inside-the-plaintext-frame.md.
    func encryptSessionControl(
        payload: Data,
        messageId: String,
        recipientId: String,
        frameAs contentType: UInt8? = nil
    ) throws -> Data {
        let plaintext = contentType.map {
            ChunkedMessageCodec.frameWhole(
                payload, contentType: $0, messageId: UUID(uuidString: messageId) ?? UUID()
            )
        } ?? payload
        return try encryptOutgoing(
            plaintext: plaintext,
            messageId: messageId,
            recipientId: recipientId,
            contentType: 0
        )
    }

    // MARK: - Session Communication

    /// Sends an encrypted heartbeat to `contactId` (content_type=13).
    /// A decrypt failure on the peer side triggers proactive session healing.
    ///
    /// IMPORTANT: Heartbeats deliberately never use Stealth/Sealed Sender,
    /// even when global stealth mode is enabled (including per-stream).
    /// See decision: decisions/stealth-heartbeat-exclusion.md
    func sendSessionHeartbeat(to contactId: String) async {
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        guard CryptoManager.shared.hasSession(for: contactId) else {
            Log.debug("Heartbeat skip for \(contactId.prefix(8))… — no active session", category: "OutboundSession")
            return
        }
        let heartbeatId = UUID().uuidString.lowercased()
        do {
            // Heartbeats intentionally do **not** use sealed sender.
            // We never pass recipientIdentityKey here.
            // The type rides in KNST byte 5, inside the ciphertext, like the call signal and the
            // delivery receipt before it. It used to be announced on the outer envelope
            // (`contentType: .heartbeat`), which let the server count liveness probes and tell
            // them apart from messages — the exact distinguishability 12/14/25/26 were moved
            // inside to remove. See decisions/sealed-content-type-inside-the-plaintext-frame.md.
            //
            // The body is empty. It used to be the string "__heartbeat__", which nothing ever
            // read: the whole codebase had one occurrence of it, this send. Routing was on the
            // content type then and is on the content type now, so the string was 13 bytes of
            // filler in the same shape as `__session_reset_notify__` — the magic string that
            // shipped with no reader and spent four months rendering as a visible bubble.
            let payload = try encryptOutgoing(
                plaintext: ChunkedMessageCodec.frameWhole(
                    Data(),
                    contentType: WireMessageKind.heartbeatContentType,
                    messageId: UUID(uuidString: heartbeatId) ?? UUID()
                ),
                messageId: heartbeatId,
                recipientId: contactId
            )
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: heartbeatId,
                recipientId: contactId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                encryptedPayload: payload,
                timestamp: UInt64(Date().timeIntervalSince1970),
                // Indistinguishable from an ordinary message on the outer envelope, which is the
                // point: the real type is in byte 5, inside the ciphertext.
                contentType: .e2EeSignal
            )
            Log.debug("Heartbeat sent to \(contactId.prefix(8))…", category: "OutboundSession")
        } catch {
            Log.error("Heartbeat failed to \(contactId.prefix(8))…: \(error.localizedDescription)", category: "OutboundSession")
        }
    }

    /// Tell `contactId` their message reached our transcript. Fire-and-forget.
    ///
    /// **This is the only receipt we send.** The plaintext stream receipt (`DirectReceipt` over
    /// `MessageStreamRequest`) was removed on 2026-08-02: it carried `recipient_user_id` — the
    /// original sender — in the clear, handing the server exactly the sender↔recipient link that
    /// sealed sender exists to withhold (`sender_id` is deliberately empty on a sealed envelope,
    /// so the client's receipt was the server's *only* source for that link). It bought nothing:
    /// the Redis trim is driven solely by `Subscribe.since_cursor`
    /// (`messaging-service/src/stream.rs`); `relay_delivery_receipt` only forwards.
    /// See decisions/stream-delivery-receipt-deanonymized-sealed-sender.md.
    ///
    /// Call this **only where the message is genuinely in the transcript.** A receipt is a claim
    /// the sender renders as a checkmark, so an untrue one is a visible lie. Control messages
    /// (END_SESSION, SRI, ping/ready, heartbeat, receipts, profile shares, edits) never have a
    /// row on the sender's side, so a receipt for one could not move anything even if sent.
    ///
    /// Resolves the recipient identity key synchronously on the caller's context queue, then
    /// hands the id to `DeliveryReceiptBatcher`. Fail-closed under stealth: dropped, never sent
    /// identified.
    ///
    /// The send is **not** immediate. Ids owed to the same contact inside the batcher's window
    /// leave as one receipt, which is what the `messageIds` list in the proto was always for. Under
    /// a redelivery replay that is the difference between one encrypt+ratchet+RPC and several
    /// hundred; a checkmark arriving half a second later is not the difference between anything.
    static func sendDeliveryReceipt(
        for messageIds: [String],
        to contactId: String,
        in context: NSManagedObjectContext
    ) {
        let identityKey: Data? = {
            guard StealthPolicy.shared.shouldUseSealedSender() else { return nil }
            let request = User.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", contactId)
            request.fetchLimit = 1
            do {
                return try context.fetch(request).first?.knownIdentityKey
            } catch {
                Log.error("Failed to load identity key for encrypted receipt to \(contactId.prefix(8))…: \(error)", category: "OutboundSession")
                return nil
            }
        }()
        Task { @MainActor in
            for messageId in messageIds {
                DeliveryReceiptBatcher.shared.enqueue(
                    messageId: messageId,
                    to: contactId,
                    recipientIdentityKey: identityKey
                )
            }
        }
    }

    /// Sends an E2E-encrypted delivery receipt (content_type=14) to `contactId`.
    ///
    /// Payload format: binary proto `Shared_Proto_Signaling_V1_DeliveryReceipt` with
    /// `.direct(DirectReceipt{ messageIds, status: .delivered, timestamp, senderDeviceID, recipientUserID })`.
    /// The binary format aligns with the binary-data-pipeline rule in AGENTS.md.
    func sendEncryptedDeliveryReceipt(
        messageIds: [String],
        to contactId: String,
        recipientIdentityKey: Data? = nil
    ) async {
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        guard CryptoManager.shared.hasSession(for: contactId) else {
            Log.debug("E2E receipt skip — no session for \(contactId.prefix(8))…", category: "OutboundSession")
            return
        }
        let receiptId = UUID().uuidString.lowercased()

        // Build binary proto payload: Shared_Proto_Signaling_V1_DeliveryReceipt
        var receipt = Shared_Proto_Signaling_V1_DeliveryReceipt()
        var direct = Shared_Proto_Signaling_V1_DirectReceipt()
        direct.messageIds = messageIds
        direct.status = .delivered
        direct.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        direct.senderDeviceID = KeychainManager.shared.loadDeviceID() ?? ""
        direct.recipientUserID = contactId
        receipt.receiptType = .direct(direct)

        guard let payloadData = try? receipt.serializedData() else {
            Log.error("E2E receipt: failed to serialize proto", category: "OutboundSession")
            return
        }

        do {
            // The type rides in KNST byte 5, inside the ciphertext. Both the orchestrator and
            // `SealedInner` are told nothing (0 / UNSPECIFIED) so the server cannot tell a receipt
            // from a message body. See decisions/sealed-content-type-inside-the-plaintext-frame.md.
            let wirePayload = try encryptOutgoing(
                plaintext: ChunkedMessageCodec.frameWhole(
                    payloadData, contentType: 14, messageId: UUID(uuidString: receiptId) ?? UUID()
                ),
                messageId: receiptId,
                recipientId: contactId,
                contentType: 0
            )
            var sealedInner: Data? = nil
            if let identityKey = recipientIdentityKey, StealthPolicy.shared.shouldUseSealedSender() {
                do {
                    sealedInner = try await StealthSenderService.buildSealedInner(
                        recipientUserId: contactId,
                        recipientIdentityKey: identityKey,
                        encryptedPayload: wirePayload,
                        contentType: .generic
                    )
                } catch {
                    Log.error("E2E receipt: seal failed: \(error)", category: "OutboundSession")
                    PerformanceMetrics.shared.record(.stealthSealFailure, label: "receipt")
                }
            }

            // Fail-closed: while stealth is on a receipt is sealed or dropped — NEVER sent identified.
            // A delivery receipt is best-effort; revealing the real senderId to deliver one would hand
            // the server the exact deanonymization sealed sender exists to prevent. Same invariant as
            // message bodies (ChunkedMessageSender / StealthSendRecovery); the identified `else` below
            // is therefore reachable only when stealth is off.
            if StealthPolicy.shared.shouldUseSealedSender() && sealedInner == nil {
                Log.error("E2E receipt: cannot seal (recipient IK/cert unavailable) — DROPPED, sender not revealed → \(contactId.prefix(8))…", category: "OutboundSession")
                PerformanceMetrics.shared.record(.stealthSealFailure, label: "receipt-dropped")
                if recipientIdentityKey == nil {
                    // No recipient identity key → nudge bundle/session so a later receipt can seal.
                    SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: contactId)
                }
                return
            }

            if let sealedInner, let identityKey = recipientIdentityKey {
                // Sealed receipt with one-shot enforce recovery (fresh token + tag on
                // privacy_pass rejection; DR payload reused). Receipts carry tokens like
                // any sealed send — no content-type exemption exists (see decisions/
                // sealed-sender-anti-abuse-economics.md); never downgrades to identified.
                _ = try await StealthSendRecovery.sendSealed(sealedInner, rebuild: {
                    try await StealthSenderService.buildSealedInner(
                        recipientUserId: contactId,
                        recipientIdentityKey: identityKey,
                        encryptedPayload: wirePayload,
                        contentType: .generic
                    )
                }, send: { inner in
                    if FeatureFlags.sealedSenderUnauthenticatedTransport {
                        // stealth-sealed-sender-v2 Phase 2: dedicated unauthenticated RPC/channel.
                        return try await MessagingServiceClient.shared.sendSealedMessage(sealedInner: inner)
                    } else {
                        return try await MessagingServiceClient.shared.sendMessage(
                            messageId: receiptId,
                            recipientId: contactId,
                            senderId: myId,
                            conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                            encryptedPayload: wirePayload,
                            timestamp: UInt64(Date().timeIntervalSince1970),
                            sealedInnerBytes: inner
                        )
                    }
                })
            } else {
                _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: receiptId,
                    recipientId: contactId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                    encryptedPayload: wirePayload,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    sealedInnerBytes: nil
                )
            }
            Log.info("E2E receipt sent: \(messageIds.count) msg(s) → \(contactId.prefix(8))…", category: "OutboundSession")
        } catch {
            Log.error("E2E receipt failed to \(contactId.prefix(8))…: \(error.localizedDescription)", category: "OutboundSession")
        }
    }

    // MARK: - Storage Action Execution

    /// Processes `saveToSecureStore` and `sessionTerminated` actions from the orchestrator.
    /// Called both internally (after outgoing encryption) and from MessageRouter (after session events).
    ///
    /// Returns `true` iff every **send-critical** persist succeeded — the hot session (`session_`)
    /// and orchestrator state, which together carry the sending-chain position. `encryptOutgoing`
    /// gates the send on this; other callers may ignore it (`@discardableResult`).
    @discardableResult
    func executeStorageActions(_ actions: [CfeAction]) -> Bool {
        var sendStateDurable = true
        for action in actions {
            switch action {
            case .saveToSecureStore(let slot, let data):
                let ok = handleStorageAction(slot: slot, data: [UInt8](data))
                sendStateDurable = sendStateDurable && ok
            case .sessionTerminated(let contactId, let archiveBytes):
                CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: archiveBytes)
                CryptoManager.shared.saveOrchestratorStateCFE()
            default:
                break
            }
        }
        return sendStateDurable
    }

    /// Unified handler for a `SaveToSecureStore` action.
    ///
    /// The core names the slot; this function is the only place that decides where the bytes go.
    /// It used to receive a formatted string and branch on `hasPrefix`, with an `else` that logged
    /// "unhandled storage key" at debug level and returned success — which is where
    /// `kyber_session_state` and `kyber_spk_<id>` had been landing, unnoticed. A `switch` over the
    /// slot cannot have that branch: a new slot stops this file compiling until it is answered.
    ///
    /// Returns `true` iff the **send-critical** persist for this action succeeded (hot session +
    /// orchestrator state). Non-send-critical saves always return `true`: their failure is logged
    /// and matters, but it cannot cause message-number reuse, so it must not block a send.
    private func handleStorageAction(slot: CfeSecureStoreSlot, data rawBytes: [UInt8]) -> Bool {
        switch slot {

        case .session(let contactId):
            guard !rawBytes.isEmpty else {
                KeychainManager.shared.deleteSession(for: contactId)
                KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
                Log.debug("Deleted hot session for \(contactId.prefix(8))… (Rust archive_session)", category: "OutboundSession")
                return CryptoManager.shared.saveOrchestratorStateCFE()
            }
            // Desync-critical: the Rust ratchet has already advanced in memory. If this
            // Keychain write fails (e.g. locked-device edge, storage error) and the failure
            // is swallowed, the persisted session lags the live ratchet → silent, unhealable
            // desync on the next launch/push. Surface the failure AND report it so
            // `encryptOutgoing` can fail-closed instead of releasing an un-persisted advance.
            let ok = KeychainManager.shared.saveSessionData(Data(rawBytes), for: contactId)
            if !ok {
                Log.error("PERSIST-FAIL hot session \(contactId.prefix(8))… (\(rawBytes.count)B) — ratchet may desync on next launch", category: "OutboundSession")
            }
            let orchOk = CryptoManager.shared.saveOrchestratorStateCFE()
            return ok && orchOk

        case .sessionArchive(let contactId):
            CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: Data(rawBytes))
            CryptoManager.shared.saveOrchestratorStateCFE()
            return true // a terminated session — not the active sending chain

        case .pqDeferred(let contactId):
            let account = KeychainSessionAccounts.account(for: slot)
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteData(forKey: account)
                Log.debug("Deleted PQ deferred for \(contactId.prefix(8))…", category: "OutboundSession")
            } else {
                // AfterFirstUnlock: this write also fires during a locked-device background
                // decrypt. Under the WhenUnlocked default it failed there, losing the deferred
                // PQ contribution and silently downgrading the session to classical (BS-6).
                let ok = KeychainManager.shared.saveData(
                    Data(rawBytes),
                    forKey: account,
                    accessible: KeychainManager.cryptoKeyAccessible
                )
                if !ok {
                    Log.error("PERSIST-FAIL PQ deferred \(contactId.prefix(8))… (\(rawBytes.count)B) — session may downgrade to classical (BS-6)", category: "OutboundSession")
                }
            }
            return true // BS-6 (downgrade), not number reuse — must not block a send

        case .kyberSessionState:
            // `PQCKeyManager.saveCFESnapshot` writes the identical bytes to the identical account
            // by pulling `exportKyberSessionState()`. This push was ignored until 2026-08-26 —
            // the string form fell into the "unhandled storage key" branch — so the pull was the
            // only thing keeping PQ state alive. Both now write the same value to the same place;
            // the push is the one that fires at the exact moment the state changes.
            guard !rawBytes.isEmpty else { return true }
            let ok = KeychainManager.shared.saveData(
                Data(rawBytes),
                forKey: KeychainSessionAccounts.kyberSessionState,
                accessible: KeychainManager.cryptoKeyAccessible
            )
            if !ok {
                Log.error("PERSIST-FAIL Kyber session state (\(rawBytes.count)B) — PQ ratchet state may desync on next launch", category: "OutboundSession")
            }
            return true

        case .kyberSignedPrekey(let keyId):
            // No reachable emitter: `commit_spk_rotation` is called only from its own tests, and
            // the Kyber SPK is rotated through `PreKeyRotationService`. Loud rather than silent —
            // if this ever fires, the rotation has two implementations and one of them is unread.
            Log.error("Unexpected KyberSignedPrekey slot (id \(keyId), \(rawBytes.count)B) — nothing reads this; see SecureStoreSlot", category: "OutboundSession")
            return true

        case .orchestratorState:
            guard !rawBytes.isEmpty else {
                Log.debug("Orchestrator state save with empty data — ignoring", category: "OutboundSession")
                return true
            }
            // AfterFirstUnlock: this Rust-driven save also fires during background
            // push decrypt while locked; WhenUnlocked would drop it → ratchet desync.
            let ok = KeychainManager.shared.saveData(
                Data(rawBytes),
                forKey: KeychainSessionAccounts.orchestratorState,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            if ok {
                Log.debug("Orchestrator state persisted (\(rawBytes.count) bytes) via Rust action", category: "OutboundSession")
            } else {
                Log.error("PERSIST-FAIL orchestrator_state (\(rawBytes.count)B) via Rust action — ratchet coordination may desync on next launch", category: "OutboundSession")
            }
            return ok // send-critical: carries the ratchet coordination state
        }
    }
}
