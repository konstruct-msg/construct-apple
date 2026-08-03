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
        // notifyError, saveSessionToSecureStore, sessionTerminated, and the rest of the
        // CfeAction surface exhaustively. See SessionActionExecutor.
        SessionActionExecutor.shared.execute(actions)
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
            let payload = try encryptOutgoing(
                plaintext: Data("__heartbeat__".utf8),
                messageId: heartbeatId,
                recipientId: contactId,
                contentType: 13
            )
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: heartbeatId,
                recipientId: contactId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                encryptedPayload: payload,
                timestamp: UInt64(Date().timeIntervalSince1970),
                contentType: .heartbeat
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
    /// hands off to the async send. Fail-closed under stealth: dropped, never sent identified.
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
            await OutboundSessionService.shared.sendEncryptedDeliveryReceipt(
                messageIds: messageIds,
                to: contactId,
                recipientIdentityKey: identityKey
            )
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
                        contentType: .unspecified
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
                        contentType: .unspecified
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

    /// Processes `saveSessionToSecureStore` and `sessionTerminated` actions from the orchestrator.
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
            case .saveSessionToSecureStore(let key, let data):
                let ok = handleStorageAction(key: key, data: [UInt8](data))
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

    /// Unified handler for a `SaveSessionToSecureStore` action.
    ///
    /// Key conventions (established by `session_lifecycle.rs`):
    /// - `"session_<contactId>"` + non-empty bytes → save hot session to Keychain
    /// - `"session_<contactId>"` + empty bytes    → delete sentinel: clear Keychain
    /// - `"archive_<contactId>"` + bytes          → accept pre-archived session from Rust
    /// - `"pq_deferred_<contactId>"` + bytes      → persist deferred PQ contribution
    /// - `"pq_deferred_<contactId>"` + empty      → delete stored PQ contribution
    ///
    /// Returns `true` iff the **send-critical** persist for this action succeeded (`session_` hot
    /// session + orchestrator state). Non-send-critical saves (`archive_`, `pq_deferred_`) always
    /// return `true`: their failure is logged and matters, but it cannot cause message-number reuse,
    /// so it must not block a send.
    private func handleStorageAction(key: String, data rawBytes: [UInt8]) -> Bool {
        if key.hasPrefix("session_") {
            let contactId = String(key.dropFirst("session_".count))
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteSession(for: contactId)
                KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
                Log.debug("Deleted hot session for \(contactId.prefix(8))… (Rust archive_session)", category: "OutboundSession")
                return CryptoManager.shared.saveOrchestratorStateCFE()
            } else {
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
            }
        } else if key.hasPrefix("archive_") {
            let contactId = String(key.dropFirst("archive_".count))
            CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: Data(rawBytes))
            CryptoManager.shared.saveOrchestratorStateCFE()
            return true // archive is a terminated session — not the active sending chain
        } else if key.hasPrefix("pq_deferred_") {
            let storageKey = "construct.pq_deferred.\(String(key.dropFirst("pq_deferred_".count)))"
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteData(forKey: storageKey)
                Log.debug("Deleted PQ deferred for key \(storageKey)", category: "OutboundSession")
            } else {
                // AfterFirstUnlock: this write also fires during a locked-device background
                // decrypt. Under the WhenUnlocked default it failed there, losing the deferred
                // PQ contribution and silently downgrading the session to classical (BS-6).
                let ok = KeychainManager.shared.saveData(
                    Data(rawBytes),
                    forKey: storageKey,
                    accessible: KeychainManager.cryptoKeyAccessible
                )
                if ok {
                    Log.debug("Persisted PQ deferred for key \(storageKey)", category: "OutboundSession")
                } else {
                    Log.error("PERSIST-FAIL PQ deferred \(storageKey) (\(rawBytes.count)B) — session may downgrade to classical (BS-6)", category: "OutboundSession")
                }
            }
            return true // PQ deferred failure is BS-6 (downgrade), not number reuse — do not block send
        } else if key == "construct.orchestrator_state" {
            if rawBytes.isEmpty {
                Log.debug("Orchestrator state save with empty data — ignoring", category: "OutboundSession")
                return true
            } else {
                // AfterFirstUnlock: this Rust-driven save also fires during background
                // push decrypt while locked; WhenUnlocked would drop it → ratchet desync.
                let ok = KeychainManager.shared.saveData(
                    Data(rawBytes),
                    forKey: "construct.orchestrator_state",
                    accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                )
                if ok {
                    Log.debug("Orchestrator state persisted (\(rawBytes.count) bytes) via Rust action", category: "OutboundSession")
                } else {
                    Log.error("PERSIST-FAIL orchestrator_state (\(rawBytes.count)B) via Rust action — ratchet coordination may desync on next launch", category: "OutboundSession")
                }
                return ok // send-critical: carries the ratchet coordination state
            }
        } else {
            Log.debug("Unhandled storage key: \(key)", category: "OutboundSession")
            return true
        }
    }
}
