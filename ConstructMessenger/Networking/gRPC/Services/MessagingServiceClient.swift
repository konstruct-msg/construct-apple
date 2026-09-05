//
//  MessagingServiceClient.swift
//  Construct Messenger
//
//  gRPC MessagingService client — replaces MessagingAPI for message sending
//

import Foundation
import CoreData
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif


final class MessagingServiceClient: Sendable {
    static let shared = MessagingServiceClient()

    private init() {}

    /// Builds the outgoing message envelope.
    ///
    /// Extracted from `sendMessage` so the sealed-sender invariant is unit-testable without a live
    /// gRPC channel. **Invariant:** a sealed send (non-empty `sealedInnerBytes`) MUST NOT populate
    /// `sender`, `conversationID`, or `contentType` on the outer envelope — those are exactly the
    /// metadata sealed sender hides (the real content_type travels inside `SealedInner`). The
    /// identified fields are set ONLY on the non-sealed path. Empty sealed bytes are treated as
    /// identified (never silently drop the sender).
    ///
    /// `recipientDeviceId` is likewise unsealed-only, for the same reason read from the other end:
    /// the outer field is visible to the relay, so on a sealed send the device travels inside
    /// `SealedInner.recipient_device` instead (field 19) and this one stays unset.
    static func buildEnvelope(
        messageId: String,
        recipientId: String,
        senderId: String,
        conversationId: String,
        encryptedPayload: Data,
        timestamp: UInt64,
        recipientDeviceId: String?,
        contentType: Shared_Proto_Core_V1_ContentType,
        sealedInnerBytes: Data?
    ) -> Shared_Proto_Core_V1_Envelope {
        var recipient = Shared_Proto_Core_V1_UserId()
        recipient.userID = recipientId

        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = messageId
        envelope.recipient = recipient
        envelope.timestamp = Int64(timestamp)

        if let sealedInner = sealedInnerBytes, !sealedInner.isEmpty {
            // STEALTH (stealth-sealed-sender-v2 Phase 3): do not populate sender, conversation_id,
            // or the real content_type on the outer envelope — the real content_type travels inside
            // SealedInner (see StealthSenderService.buildSealedInner) and is recovered by the
            // recipient after unsealing.
            var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
            sealedEnvelope.sealedInner = sealedInner
            // Read by the federation forward (`send_sealed_message(target, id, inner, timestamp)`)
            // and never written until 2026-08-17 — every federated sealed message carried 0. A
            // consumer with no producer, the mirror of the defect class this envelope keeps
            // producing.
            sealedEnvelope.timestamp = Int64(timestamp)
            envelope.sealedSender = sealedEnvelope
        } else {
            // Only the unsealed path puts the ciphertext here. A sealed send carries the identical
            // bytes inside `SealedInner.encrypted_payload`, and the relay drops this copy: the
            // sealed branch of `send_message` returns before reading it, and the envelope it
            // delivers is rebuilt by `MessageEnvelope::from_sealed_sender` out of `sealed_inner`
            // alone. So the padded ciphertext — 1024, 4096 or 16384 bytes, per chunk — used to go
            // up the wire twice on every message this app sends.
            envelope.encryptedPayload = encryptedPayload
            var sender = Shared_Proto_Core_V1_UserId()
            sender.userID = senderId
            envelope.sender = sender
            envelope.conversationID = conversationId
            envelope.contentType = contentType

            // Restored 2026-08-30. Both device fields were dropped here on 2026-08-17 because
            // nothing read them — measured, and true at the time. `recipient_device` acquired a
            // reader on 2026-08-29 (`construct-server@619bad8` routes on it), and the removal
            // outlived its reason: three fan-out call sites went on passing a device id that this
            // function discarded, so every unsealed copy addressed to one device was still written
            // to every device of the account. N copies × N devices.
            //
            // `sender_device` stays unset and its parameter is gone. The server blanks it on
            // delivery on purpose — server metadata must not carry E2E meaning — so it has no
            // reader by design, not by omission. Telling the recipient which device sent is §D's
            // job, and §D does it with a MAC under a shared secret (`SenderSyncDeviceTag`).
            if let device = recipientDeviceId, !device.isEmpty {
                var recipientDevice = Shared_Proto_Core_V1_DeviceId()
                recipientDevice.deviceID = device
                envelope.recipientDevice = recipientDevice
            }
        }

        return envelope
    }

    // MARK: - Send Message (replaces MessagingAPI.sendMessage)

    func sendMessage(
        messageId: String,
        recipientId: String,
        senderId: String,
        conversationId: String,
        encryptedPayload: Data,
        timestamp: UInt64,
        recipientDeviceId: String? = nil,
        contentType: Shared_Proto_Core_V1_ContentType = .e2EeSignal,
        sealing: SendSealing
    ) async throws -> SendMessageResponse {
        // The chokepoint. Sealing is the default here and an exemption is a named value, so a
        // send path that does not answer does not compile, and one that answers wrongly fails
        // closed. Before 2026-08-30 each caller decided alone and the exclusions lived in a doc
        // comment on StealthPolicy; two accumulated there unnoticed.
        if let reason = sealing.violation(stealthEnabled: await StealthPolicy.shared.isEnabled) {
            throw StealthDowngradeBlocked(reason: "\(reason) → \(recipientId.prefix(8))…")
        }
        let sealedInnerBytes = sealing.sealedInnerBytes
        // Acquire a UIBackgroundTask so iOS cannot tear down the network connection
        // while the RPC is in flight (send_message typically takes ~150ms).
        // Without this, backgrounding immediately after Send kills the connection
        // before the server response arrives → client never sees success=true → retry storm.
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "send-msg-rpc") { } }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) } }
        #endif
        // §D. The same chokepoint reasoning as sealing above: the device that wrote a copy has to
        // be nameable to its recipient, and a per-caller decision drifted here once already. The
        // fan-out has tagged its copies since 2026-08-17; `primarySendCovered` is exactly what
        // keeps the recipient's pinned device *out* of that fan-out, so the one target receiving
        // most of the traffic was the one arriving unattributable.
        //
        // Returns the id unchanged when nothing can attribute it — a fan-out copy that is already
        // tagged, a first contact with no pinned key, an unreadable Keychain — and the receiver
        // then walks its sessions exactly as before.
        let wireMessageId = PrimarySendTag.wireId(
            baseMessageId: messageId,
            recipientId: recipientId,
            recipientDeviceId: recipientDeviceId
        )
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            let envelope = Self.buildEnvelope(
                messageId: wireMessageId,
                recipientId: recipientId,
                senderId: senderId,
                conversationId: conversationId,
                encryptedPayload: encryptedPayload,
                timestamp: timestamp,
                recipientDeviceId: recipientDeviceId,
                contentType: contentType,
                sealedInnerBytes: sealedInnerBytes
            )

            let attemptId = UUID().uuidString.lowercased()

            var request = Shared_Proto_Services_V1_SendMessageRequest()
            request.message = envelope
            request.idempotencyKey = messageId
            request.attemptID = attemptId

            Log.debug("""
                   sendMessage RPC →
                   messageId      = \(messageId)
                   attemptId      = \(attemptId)
                   senderId       = \(sealedInnerBytes != nil ? "[STEALTH]" : senderId)
                   recipientId    = \(recipientId)
                   conversationId = \(conversationId)
                   payloadBytes   = \(encryptedPayload.count)
                """, category: "MessagingServiceClient")

            let response = try await msgClient.sendMessage(
                request: .init(message: request)
            )

            let errorCodeRaw = response.error.errorCode
            let retryAfterMs = response.error.hasRetryAfterMs ? response.error.retryAfterMs : 0
            let echoedAttemptId = response.hasAttemptID ? response.attemptID : attemptId

            let status: String
            let retryable: Bool
            let errorCodeStr: String
            if response.success {
                status = "sent"
                retryable = true
                errorCodeStr = ""
                Log.info("sendMessage sent attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .blocked {
                status = "blocked"
                retryable = false
                errorCodeStr = "blocked"
                Log.error("Message blocked by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .rateLimit {
                status = "failed"
                retryable = true
                errorCodeStr = "rateLimit"
                Log.error("Rate limited — attemptId=\(echoedAttemptId) retryAfterMs=\(retryAfterMs) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .encryptionFailed {
                status = "failed"
                retryable = false
                errorCodeStr = "encryptionFailed"
                Log.error("Encryption rejected by server — attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
                errorCodeStr = errorCodeRaw == .unspecified ? "" : "\(errorCodeRaw)"
                Log.error("sendMessage failed — attemptId=\(echoedAttemptId) errorCode=\(errorCodeRaw) retryable=\(retryable) messageId=\(response.messageID)", category: "MessagingServiceClient")
            }

            return SendMessageResponse(
                messageId: response.messageID,
                status: status,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Send Sealed Message (stealth-sealed-sender-v2 Phase 2)

    /// Sends a sealed-sender message over the unauthenticated sealed channel via the
    /// new `SendSealedMessage` RPC — no outer `Envelope`, no sender/conversation_id/
    /// content_type on the wire. Gated by `FeatureFlags.sealedSenderUnauthenticatedTransport`;
    /// callers should fall back to `sendMessage(sealedInnerBytes:)` when the flag is off.
    func sendSealedMessage(sealedInner: Data) async throws -> SendMessageResponse {
        // Sealed by construction, with one way to be wrong: empty bytes. This RPC has no outer
        // envelope at all, so an empty inner is not a downgrade to identified — it is an
        // undeliverable envelope the relay accepts and no one can route.
        if let reason = SendSealing.sealed(sealedInner).violation(stealthEnabled: true) {
            throw StealthDowngradeBlocked(reason: reason)
        }
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "send-sealed-msg-rpc") { } }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) } }
        #endif
        return try await GRPCChannelManager.shared.performSealedRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
            sealedEnvelope.sealedInner = sealedInner

            let attemptId = UUID().uuidString.lowercased()

            var request = Shared_Proto_Services_V1_SendSealedMessageRequest()
            request.sealedSender = sealedEnvelope
            request.attemptID = attemptId

            Log.debug("sendSealedMessage RPC → attemptId=\(attemptId) payloadBytes=\(sealedInner.count)", category: "MessagingServiceClient")

            let response = try await msgClient.sendSealedMessage(request: .init(message: request))

            let errorCodeRaw = response.error.errorCode
            let retryAfterMs = response.error.hasRetryAfterMs ? response.error.retryAfterMs : 0
            let echoedAttemptId = response.hasAttemptID ? response.attemptID : attemptId

            let status: String
            let retryable: Bool
            let errorCodeStr: String
            if response.success {
                status = "sent"
                retryable = true
                errorCodeStr = ""
                Log.info("sendSealedMessage sent attemptId=\(echoedAttemptId) messageId=\(response.messageID)", category: "MessagingServiceClient")
            } else if errorCodeRaw == .rateLimit {
                status = "failed"
                retryable = true
                errorCodeStr = "rateLimit"
                Log.error("sendSealedMessage rate limited — attemptId=\(echoedAttemptId) retryAfterMs=\(retryAfterMs)", category: "MessagingServiceClient")
            } else {
                status = "failed"
                retryable = response.error.retryable
                errorCodeStr = errorCodeRaw == .unspecified ? "" : "\(errorCodeRaw)"
                Log.error("sendSealedMessage failed — attemptId=\(echoedAttemptId) errorCode=\(errorCodeRaw) retryable=\(retryable)", category: "MessagingServiceClient")
            }

            return SendMessageResponse(
                messageId: response.messageID,
                status: status,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Send End Session (replaces MessagingAPI.sendEndSession)

    /// - Parameter resetReason: optional machine-readable recovery hint telling the peer HOW to
    ///   re-initialise — notably `.otpkUnreproducible`, which asks the initiator to re-init WITHOUT
    ///   a one-time prekey (3-DH) instead of looping 4-DH. It is sealed to the peer's identity key
    ///   and padded to a fixed size by `EndSessionPayload`; a peer that cannot read it recovers
    ///   without a hint, which is what every peer did before hints existed.
    /// Tear down the session with **one device**.
    ///
    /// `deviceId` is a `CryptoDeviceId`, and that is the whole point. This used to take whatever
    /// its caller held — an account id from the router paths, a device id from the core's actions —
    /// and pass `recipientDeviceId: nil` either way. Both halves were wrong, mirror-image:
    ///
    /// - An account id reached **every** device's queue, so a divergence with one device tore down
    ///   the healthy sessions of its siblings.
    /// - A device id went into `Envelope.recipient`, a field in the account space, where the server
    ///   parses a UUID, gets none, and writes the envelope to a stream nothing subscribes to.
    ///   Accepted, acknowledged, delivered nowhere — the same defect §B.4 closed for the heartbeat
    ///   (`b29ea419`), left standing on the neighbouring path.
    ///
    /// Both were measured on 2026-08-30: 12 sends to a device and 10 to an account, one peer, one
    /// run. Fanning out over a peer's devices is the caller's job now
    /// (`SessionAddressing.deviceIds` + the core's `planTeardown`), so this function has exactly one
    /// recipient and no
    /// opinion about how many there were.
    func sendEndSession(
        toDevice deviceId: String,
        reason: String? = nil,
        resetReason: Shared_Proto_Messaging_V1_SessionResetReason = .unspecified
    ) async throws -> EndSessionResponse {
        let myUserId = await MainActor.run { AuthSessionManager.shared.currentUserId } ?? ""
        let messageId = UUID().uuidString

        // The account to address and the key to seal to, from one row and one pass. Asked
        // separately they could come from different contacts, and the envelope would then be
        // addressed to one person and sealed to another — undeliverable, and undetectable from
        // either side. Same seam the heartbeat takes, for the same reason.
        guard let peer = await MainActor.run(resultType: (accountId: String, identityKey: Data)?.self, body: {
            SessionAddressing.peer(
                ofDevice: deviceId,
                in: PersistenceController.shared.container.viewContext
            )
        }) else {
            throw StealthDowngradeBlocked(
                reason: "no pinned key for device \(deviceId.prefix(8))… — END_SESSION cannot be addressed"
            )
        }
        let recipientId = peer.accountId

        // Stealth: seal END_SESSION like a message body — the real content type (.sessionReset)
        // rides inside SealedInner and is recovered on receive, so the outer envelope leaks no
        // sender. Sealing is X25519 cert-based, independent of the (possibly broken) DR session, so
        // it works during teardown. Fail-closed under stealth-on: never emit an identified
        // END_SESSION (decisions/sealed-sender-session-control-channel.md). If we can't seal, the
        // peer recovers via its own decrypt-fail path — anonymity over an eager teardown signal.
        //
        // The key is the **target device's**, not the account's pin. Sealing to it is also what
        // routes the envelope: `buildSealedInner` derives `SealedInner.recipient_device` from the
        // key it seals to, so "who can open this" and "where does it go" stay one value (§A.0).
        func resolveRecipientIK() async -> Data? { peer.identityKey }

        // Built before the stealth branch, and deliberately: `buildEnvelope` fills
        // `encrypted_payload` *before* it decides whether the send is sealed, so this payload is on
        // the wire under stealth exactly as it is without it. Until 2026-08-17 that meant the relay
        // read a plaintext reset reason on a 4- or 16-byte envelope — a length no padded body has —
        // while `SealedInner` was busy hiding the content type. See EndSessionPayload.
        let controlPayload = EndSessionPayload.build(
            reason: resetReason,
            recipientIdentityKey: await resolveRecipientIK()
        )

        // Named `endSessionSealing`, not `sealing`: `SealingExemptionSiteTests` reads this file
        // as text to prove the chokepoint's parameter has no default, and a local of the same
        // type and name reads as one.
        var endSessionSealing: SendSealing = .identified(.stealthDisabled)
        if await StealthPolicy.shared.shouldUseSealedSender() {
            guard let recipientIK = await resolveRecipientIK() else {
                throw StealthDowngradeBlocked(reason: "no recipient identity key for END_SESSION → \(recipientId.prefix(8))…")
            }
            endSessionSealing = .sealed(try await StealthSenderService.buildSealedInner(
                recipientUserId: recipientId,
                recipientIdentityKey: recipientIK,
                encryptedPayload: controlPayload,
                contentType: .sessionReset
            ))
        }
        // END_SESSION does not go through `sendMessage` — it has its own RPC — so it asks the
        // same question here rather than inheriting the chokepoint's answer. Two send functions,
        // one policy.
        if let reason = endSessionSealing.violation(stealthEnabled: await StealthPolicy.shared.isEnabled) {
            throw StealthDowngradeBlocked(reason: "\(reason) → \(recipientId.prefix(8))…")
        }
        let sealedInner: Data? = endSessionSealing.sealedInnerBytes

        let sendOnce: (Data?) async throws -> EndSessionResponse = { inner in
            try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.endSession) { grpcClient in
                let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

                let envelope = Self.buildEnvelope(
                    messageId: messageId,
                    recipientId: recipientId,
                    senderId: myUserId,
                    // Empty on purpose. `direct:<me>:<them>` names the person on the other side in
                    // the clear, on an envelope whose whole point is that the relay learns nothing
                    // about the pair — and it used to carry `direct:<account>:<device>` besides,
                    // both id spaces in one string. It has no reader on the server and is blanked
                    // on delivery. Same emptying as the fan-out and the heartbeat.
                    conversationId: "",
                    encryptedPayload: controlPayload,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    // `buildEnvelope` writes this only on the unsealed branch: on the sealed one the
                    // device rides inside `SealedInner`, because the outer field is visible to the
                    // relay (`8e390f48`). Passing it here is what makes the DEBUG stealth-off path
                    // route to one device instead of all of them.
                    recipientDeviceId: deviceId,
                    contentType: .sessionReset,
                    sealedInnerBytes: inner
                )

                var request = Shared_Proto_Services_V1_SendMessageRequest()
                request.message = envelope
                request.idempotencyKey = messageId

                let response = try await msgClient.sendMessage(
                    request: .init(message: request)
                )

                return EndSessionResponse(
                    status: response.success ? "ok" : "failed",
                    messageId: response.messageID,
                    type: "END_SESSION"
                )
            }
        }

        // Sealed path gets the same one-shot Privacy-Pass enforce recovery as message bodies
        // (rebuild = fresh token + delivery tag around the same control payload).
        if let sealedInner {
            return try await StealthSendRecovery.sendSealed(sealedInner, rebuild: {
                guard let ik = await resolveRecipientIK() else { return nil }
                return try await StealthSenderService.buildSealedInner(
                    recipientUserId: recipientId,
                    recipientIdentityKey: ik,
                    encryptedPayload: controlPayload,
                    contentType: .sessionReset
                )
            }, send: sendOnce)
        }
        return try await sendOnce(nil)
    }

    // MARK: - Get Pending Messages (for background fetch)

    struct FailedMessage: Sendable {
        let id: String
        let senderId: String
    }

    struct PendingMessagesResult: Sendable {
        let messages: [ChatMessage]
        /// Messages that arrived but could not be decoded (e.g. lost session key).
        /// The client should ACK these as `.failed` so the server removes them from the pending queue.
        let failedMessages: [FailedMessage]
        let nextCursor: String
        let hasMore: Bool
    }

    static func getPendingMessagesPage(
        grpcClient: GRPCClient<HTTP2ClientTransport.TransportServices>,
        sinceCursor: String? = nil,
        limit: Int32 = 50
    ) async throws -> PendingMessagesResult {
        let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

        var request = Shared_Proto_Services_V1_GetPendingMessagesRequest()
        if let sinceCursor, !sinceCursor.isEmpty {
            request.sinceCursor = sinceCursor
        }
        request.limit = limit

        let response = try await msgClient.getPendingMessages(
            request: .init(message: request)
        )

        var failed: [FailedMessage] = []
        let chatMessages = response.messages.compactMap { msg -> ChatMessage? in
            // SESSION_RESET_INIT: identified path — sealed deliveries use the generic path below.
            if msg.contentType == .sessionResetInit {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("Failed to decode SESSION_RESET_INIT payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                Log.debug("SESSION_RESET_INIT pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    rawPayload: msg.encryptedPayload
                )
            }
            // END_SESSION: contentType is the sole classifier (size heuristic removed).
            if msg.contentType == .sessionReset {
                Log.debug("END_SESSION pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: Data(),
                    suiteId: 1,
                    timestamp: UInt64(msg.timestamp),
                    kemCiphertext: Data(),
                    contentType: 21,
                    kyberOtpkId: 0,
                    rawPayload: msg.encryptedPayload
                )
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session.
            // Note: PendingMessage proto does not yet carry senderDevice/conversationID;
            // those fields are only available in the live stream Envelope.
            // Leave them empty here — handleSenderSync will ACK and skip if unable to route.
            if msg.contentType == .senderSync {
                guard let decoded = try? WirePayloadCoder.decode(msg.encryptedPayload) else {
                    Log.debug("Failed to decode SENDER_SYNC payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: decoded.suiteId,
                    timestamp: UInt64(msg.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 23,
                    kyberOtpkId: decoded.kyberOtpkId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: decoded.pqRatchetField,
                    senderDeviceId: "",
                    conversationId: ""
                )
            }
            // Unpack wire payload blob into crypto components.
            // For STEALTH messages, `sealedInnerData` is populated and `senderID` is empty.
            let sealedInner = msg.sealedInnerData
            let isSealed = !sealedInner.isEmpty
            var wirePayload = msg.encryptedPayload
            var sealedInnerPayload = Data()
            if isSealed {
                if let sealedProto = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInner) {
                    sealedInnerPayload = sealedProto.encryptedPayload
                    if wirePayload.isEmpty && !sealedInnerPayload.isEmpty {
                        wirePayload = sealedInnerPayload
                    }
                }
            }
            guard let decoded = try? WirePayloadCoder.decode(wirePayload) else {
                if isSealed {
                    // Fallback for sealed control whose inner is not a WirePayload.
                    // Preserve rawPayload so SessionControl.reason survives unseal.
                    let preservedPayload = !wirePayload.isEmpty ? wirePayload : sealedInnerPayload
                    return ChatMessage(
                        id: msg.messageID,
                        from: "",
                        to: "",
                        ephemeralPublicKey: Data(),
                        messageNumber: 0,
                        content: Data(),
                        suiteId: 1,
                        timestamp: UInt64(msg.timestamp),
                        kemCiphertext: Data(),
                        contentType: UInt8(clamping: msg.contentType.rawValue),
                        rawPayload: preservedPayload,
                        sealedInnerData: sealedInner
                    )
                }
                Log.debug("Failed to decode encrypted_payload for message \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                return nil
            }
            return ChatMessage(
                id: msg.messageID,
                from: isSealed ? "" : msg.senderID,
                to: "",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: decoded.suiteId,
                timestamp: UInt64(msg.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(clamping: msg.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                pqMessageEpoch: decoded.pqMessageEpoch,
                pqRatchetField: decoded.pqRatchetField,
                senderDeviceId: "",
                conversationId: "",
                rawPayload: wirePayload,
                sealedInnerData: sealedInner
            )
        }

        return PendingMessagesResult(
            messages: chatMessages,
            failedMessages: failed,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore_p
        )
    }

    func getPendingMessages(sinceCursor: String? = nil, limit: Int32 = 50) async throws -> PendingMessagesResult {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPendingMessages) { grpcClient in
            try await Self.getPendingMessagesPage(grpcClient: grpcClient, sinceCursor: sinceCursor, limit: limit)
        }
    }

    // MARK: - Edit Message

    func editMessage(
        messageId: String,
        conversationId: String,
        newEncryptedContent: Data,
        recipientUserId: String
    ) async throws -> Shared_Proto_Services_V1_EditMessageResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.editMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_EditMessageRequest()
            request.messageID = messageId
            request.conversationID = conversationId
            request.newEncryptedContent = newEncryptedContent
            request.recipientUserID = recipientUserId

            Log.debug("editMessage RPC → messageId=\(messageId.prefix(8))…", category: "MessagingServiceClient")

            let response = try await msgClient.editMessage(
                request: .init(message: request)
            )
            Log.info("editMessage response: success=\(response.success) editCount=\(response.editCount)", category: "MessagingServiceClient")
            return response
        }
    }
}
