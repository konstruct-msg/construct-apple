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

import Foundation
import SwiftProtobuf

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
        executeStorageActions(actions)
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
        try encryptOutgoing(
            plaintext: Data(plaintext.utf8),
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
            let wirePayload = try encryptOutgoing(
                plaintext: payloadData,
                messageId: receiptId,
                recipientId: contactId,
                contentType: 14
            )
            var sealedInner: Data? = nil
            if let identityKey = recipientIdentityKey, StealthPolicy.shared.shouldUseSealedSender() {
                do {
                    sealedInner = try await StealthSenderService.buildSealedInner(
                        recipientUserId: contactId,
                        recipientIdentityKey: identityKey,
                        encryptedPayload: wirePayload
                    )
                } catch {
                    Log.error("E2E receipt: seal failed, sending without stealth: \(error)", category: "OutboundSession")
                }
            }
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: receiptId,
                recipientId: contactId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: contactId),
                encryptedPayload: wirePayload,
                timestamp: UInt64(Date().timeIntervalSince1970),
                contentType: .deliveryReceipt,
                sealedInnerBytes: sealedInner
            )
            Log.info("E2E receipt sent: \(messageIds.count) msg(s) → \(contactId.prefix(8))…", category: "OutboundSession")
        } catch {
            Log.error("E2E receipt failed to \(contactId.prefix(8))…: \(error.localizedDescription)", category: "OutboundSession")
        }
    }

    // MARK: - Storage Action Execution

    /// Processes `saveSessionToSecureStore` and `sessionTerminated` actions from the orchestrator.
    /// Called both internally (after outgoing encryption) and from MessageRouter (after session events).
    func executeStorageActions(_ actions: [CfeAction]) {
        for action in actions {
            switch action {
            case .saveSessionToSecureStore(let key, let data):
                handleStorageAction(key: key, data: [UInt8](data))
            case .sessionTerminated(let contactId, let archiveBytes):
                CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: archiveBytes)
                CryptoManager.shared.saveOrchestratorStateCFE()
            default:
                break
            }
        }
    }

    /// Unified handler for a `SaveSessionToSecureStore` action.
    ///
    /// Key conventions (established by `session_lifecycle.rs`):
    /// - `"session_<contactId>"` + non-empty bytes → save hot session to Keychain
    /// - `"session_<contactId>"` + empty bytes    → delete sentinel: clear Keychain
    /// - `"archive_<contactId>"` + bytes          → accept pre-archived session from Rust
    /// - `"pq_deferred_<contactId>"` + bytes      → persist deferred PQ contribution
    /// - `"pq_deferred_<contactId>"` + empty      → delete stored PQ contribution
    private func handleStorageAction(key: String, data rawBytes: [UInt8]) {
        if key.hasPrefix("session_") {
            let contactId = String(key.dropFirst("session_".count))
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteSession(for: contactId)
                KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
                Log.debug("Deleted hot session for \(contactId.prefix(8))… (Rust archive_session)", category: "OutboundSession")
                CryptoManager.shared.saveOrchestratorStateCFE()
            } else {
                _ = KeychainManager.shared.saveSessionData(Data(rawBytes), for: contactId)
                CryptoManager.shared.saveOrchestratorStateCFE()
            }
        } else if key.hasPrefix("archive_") {
            let contactId = String(key.dropFirst("archive_".count))
            CryptoManager.shared.acceptSessionTerminated(contactId: contactId, archiveBytes: Data(rawBytes))
            CryptoManager.shared.saveOrchestratorStateCFE()
        } else if key.hasPrefix("pq_deferred_") {
            let storageKey = "construct.pq_deferred.\(String(key.dropFirst("pq_deferred_".count)))"
            if rawBytes.isEmpty {
                KeychainManager.shared.deleteData(forKey: storageKey)
                Log.debug("Deleted PQ deferred for key \(storageKey)", category: "OutboundSession")
            } else {
                _ = KeychainManager.shared.saveData(Data(rawBytes), forKey: storageKey)
                Log.debug("Persisted PQ deferred for key \(storageKey)", category: "OutboundSession")
            }
        } else if key == "construct.orchestrator_state" {
            if rawBytes.isEmpty {
                Log.debug("Orchestrator state save with empty data — ignoring", category: "OutboundSession")
            } else {
                // AfterFirstUnlock: this Rust-driven save also fires during background
                // push decrypt while locked; WhenUnlocked would drop it → ratchet desync.
                _ = KeychainManager.shared.saveData(
                    Data(rawBytes),
                    forKey: "construct.orchestrator_state",
                    accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                )
                Log.debug("Orchestrator state persisted (\(rawBytes.count) bytes) via Rust action", category: "OutboundSession")
            }
        } else {
            Log.debug("Unhandled storage key: \(key)", category: "OutboundSession")
        }
    }
}
