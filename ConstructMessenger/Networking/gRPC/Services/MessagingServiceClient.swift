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

    /// Builds an identified envelope — the authenticated `SendMessage` door, which since
    /// 2026-09-28 carries only unsealed traffic (own-device copies, and stealth-off DEBUG sends).
    ///
    /// There is no sealed branch. Until 2026-09-28 a sealed send also came through here and went
    /// up the authenticated channel with a Bearer token beside it, so the relay saw the sender of
    /// every sealed envelope live — the seal hid the pair from the stored envelope and from nobody
    /// who watched the request. A sealed send is `buildSealedRequest` and nothing else, and the
    /// absence of a sealed parameter here is what keeps the two doors from meeting again.
    ///
    /// Extracted from `sendMessage` so the envelope is unit-testable without a live gRPC channel.
    static func buildEnvelope(
        messageId: String,
        recipientId: String,
        senderId: String,
        conversationId: String,
        encryptedPayload: Data,
        timestamp: UInt64,
        recipientDeviceId: String?,
        contentType: Shared_Proto_Core_V1_ContentType
    ) -> Shared_Proto_Core_V1_Envelope {
        var recipient = Shared_Proto_Core_V1_UserId()
        recipient.userID = recipientId

        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = messageId
        envelope.recipient = recipient
        envelope.timestamp = Int64(timestamp)
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

        return envelope
    }

    /// Builds the request for the unauthenticated `SendSealedMessage` door — the only way a
    /// sealed envelope leaves this app.
    ///
    /// Everything that names the pair, the device or the content type is inside `sealedInner`
    /// (`StealthSenderService.buildSealedInner`); the request has no field that could carry them.
    /// No message id either: the relay assigns one on dispatch, on both doors alike.
    ///
    /// `timestamp` is read by the federation forward (`send_sealed_message(target, id, inner,
    /// timestamp)`). It was never written until 2026-08-17 — every federated sealed message
    /// carried 0 — and the dedicated RPC dropped it again until 2026-09-28, when this became the
    /// only door.
    static func buildSealedRequest(
        sealedInner: Data,
        timestamp: UInt64,
        attemptId: String
    ) -> Shared_Proto_Services_V1_SendSealedMessageRequest {
        var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
        sealedEnvelope.sealedInner = sealedInner
        sealedEnvelope.timestamp = Int64(timestamp)

        var request = Shared_Proto_Services_V1_SendSealedMessageRequest()
        request.sealedSender = sealedEnvelope
        request.attemptID = attemptId
        return request
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
        // Which door. A sealed envelope goes over the channel that carries no credentials; one
        // sent beside a Bearer token names its sender to the relay however well it is sealed.
        // Decided here and not by each caller: until 2026-09-28 the choice was a compile-time
        // flag read at two call sites, and every other sealed send — decryption errors,
        // heartbeats, receipts — went up the authenticated channel whatever the flag said.
        switch sealing {
        case .sealed(let inner):
            return try await sendSealedMessage(sealedInner: inner, timestamp: timestamp)
        case .identified:
            break
        }
        // Acquire a UIBackgroundTask so iOS cannot tear down the network connection
        // while the RPC is in flight (send_message typically takes ~150ms).
        // Without this, backgrounding immediately after Send kills the connection
        // before the server response arrives → client never sees success=true → retry storm.
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "send-msg-rpc") { } }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) } }
        #endif
        // §D. The same chokepoint reasoning as sealing above: the device that wrote a copy has to
        // be nameable to its recipient, and a per-caller decision drifted here once already. A
        // message copy arrives tagged by `DeviceDeliveryPlan.wireId`; what comes here bare is the
        // traffic that still addresses an account — controls, receipts — and is tagged for the
        // device the seam resolves, or the one the caller named.
        //
        // Returns the id unchanged when nothing can attribute it — a copy that is already tagged,
        // a first contact with no pinned key, an unreadable Keychain — and the receiver then walks
        // its sessions exactly as before.
        let wireMessageId = AccountSendTag.wireId(
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
                contentType: contentType
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
                   senderId       = \(senderId)
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
                messageNumber: response.messageNumber,
                serverTimestamp: response.serverTimestamp,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Intake tags

    /// Tell the server which intake tags this account accepts, so envelopes from vouched contacts
    /// owe no Privacy Pass token.
    ///
    /// Authenticated on purpose — the server takes the account from our credentials and ignores
    /// anything we might put in the body, because a request-supplied id would make publishing a
    /// way to vouch for someone else's incoming traffic.
    ///
    /// Returns how many entries landed. Fewer than sent is not an error: an epoch already past its
    /// grace or a window longer than the server's cap is dropped entry by entry, and a partly
    /// usable publish beats a refused one.
    func publishIntakeTags(_ entries: [(epoch: UInt64, tag: Data)]) async throws -> UInt32 {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.sendMessage) { grpcClient in
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_PublishIntakeTagsRequest()
            request.tags = entries.map { entry in
                var e = Shared_Proto_Services_V1_IntakeTagEntry()
                e.epoch = entry.epoch
                e.tag = entry.tag
                return e
            }
            let response = try await msgClient.publishIntakeTags(request: .init(message: request))
            return response.accepted
        }
    }

    // MARK: - Send Sealed Message (stealth-sealed-sender-v2 Phase 2)

    /// Sends a sealed-sender message over the unauthenticated sealed channel via the
    /// `SendSealedMessage` RPC — no outer `Envelope`, no sender/conversation_id/content_type on
    /// the wire, and no credentials on the connection. Reached through `sendMessage(sealing:
    /// .sealed)`; the only direct caller is `sendDecryptionError`.
    func sendSealedMessage(sealedInner: Data, timestamp: UInt64) async throws -> SendMessageResponse {
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

            let attemptId = UUID().uuidString.lowercased()
            let request = Self.buildSealedRequest(
                sealedInner: sealedInner,
                timestamp: timestamp,
                attemptId: attemptId
            )

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
                messageNumber: response.messageNumber,
                serverTimestamp: response.serverTimestamp,
                retryable: retryable,
                errorCode: errorCodeStr,
                retryAfterMs: retryAfterMs,
                attemptId: echoedAttemptId
            )
        }
    }

    // MARK: - Send Decryption Error

    /// Tell **one device** we could not read a message it sent: a DECRYPTION_ERROR envelope
    /// (content type 28) carrying `payload`, which the core built and sealed to that device's
    /// identity key (`CfeAction.sendDecryptionError`). This app adds nothing to it.
    ///
    /// It replaced `sendEndSession` on 2026-09-27 (`decisions/sessions-renew-by-sending.md`,
    /// variant B), and keeps its addressing, for the reasons that function learned the hard way:
    ///
    /// - `deviceId` is a `CryptoDeviceId`. An account id reached **every** device's queue; a device
    ///   id in `Envelope.recipient` went to a stream nothing subscribes to (both measured
    ///   2026-08-30).
    /// - The account and the key it is sealed to come from one row in one pass, so the envelope
    ///   cannot be addressed to one person and sealed to another.
    /// - Sealed like a message body, fail-closed under stealth: the content type rides inside
    ///   `SealedInner`, and an identified control envelope is never emitted.
    func sendDecryptionError(toDevice deviceId: String, payload: Data) async throws -> ControlSendResponse {
        let myUserId = await MainActor.run { AuthSessionManager.shared.currentUserId } ?? ""
        let messageId = UUID().uuidString

        guard let peer = await MainActor.run(resultType: (accountId: String, identityKey: Data)?.self, body: {
            SessionAddressing.peer(
                ofDevice: deviceId,
                in: PersistenceController.shared.container.viewContext
            )
        }) else {
            throw StealthDowngradeBlocked(
                reason: "no pinned key for device \(deviceId.prefix(8))… — DECRYPTION_ERROR cannot be addressed"
            )
        }
        let recipientId = peer.accountId

        // Named `decryptionErrorSealing`, not `sealing`: `SealingExemptionSiteTests` reads this
        // file as text to prove the chokepoint's parameter has no default, and a local of the same
        // type and name reads as one.
        var decryptionErrorSealing: SendSealing = .identified(.stealthDisabled)
        if await StealthPolicy.shared.shouldUseSealedSender() {
            decryptionErrorSealing = .sealed(try await StealthSenderService.buildSealedInner(
                recipientUserId: recipientId,
                recipientIdentityKey: peer.identityKey,
                encryptedPayload: payload,
                contentType: .decryptionError
            ))
        }
        // Not sent through `sendMessage`, so it asks the chokepoint's question itself. Two send
        // functions, one policy.
        if let reason = decryptionErrorSealing.violation(stealthEnabled: await StealthPolicy.shared.isEnabled) {
            throw StealthDowngradeBlocked(reason: "\(reason) → \(recipientId.prefix(8))…")
        }
        let timestamp = UInt64(Date().timeIntervalSince1970)

        switch decryptionErrorSealing {
        case .sealed(let sealedInner):
            // The unauthenticated door, with the same one-shot Privacy-Pass enforce recovery as
            // message bodies.
            let response = try await StealthSendRecovery.sendSealed(sealedInner, rebuild: { afterCredentialRejection in
                try await StealthSenderService.buildSealedInner(
                    recipientUserId: recipientId,
                    recipientIdentityKey: peer.identityKey,
                    encryptedPayload: payload,
                    contentType: .decryptionError,
                    afterCredentialRejection: afterCredentialRejection
                )
            }, send: { inner in
                try await self.sendSealedMessage(sealedInner: inner, timestamp: timestamp)
            })
            return ControlSendResponse(
                status: response.status == "sent" ? "ok" : "failed",
                messageId: response.messageId
            )

        case .identified:
            // Stealth off (DEBUG): the authenticated door, naming the device on the envelope.
            return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.controlSend) { grpcClient in
                let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

                let envelope = Self.buildEnvelope(
                    messageId: messageId,
                    recipientId: recipientId,
                    senderId: myUserId,
                    // Empty on purpose: a conversation id names the pair in the clear.
                    conversationId: "",
                    encryptedPayload: payload,
                    timestamp: timestamp,
                    recipientDeviceId: deviceId,
                    contentType: .decryptionError
                )

                var request = Shared_Proto_Services_V1_SendMessageRequest()
                request.message = envelope
                request.idempotencyKey = messageId

                let response = try await msgClient.sendMessage(
                    request: .init(message: request)
                )

                return ControlSendResponse(
                    status: response.success ? "ok" : "failed",
                    messageId: response.messageID
                )
            }
        }
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
        let chatMessages = response.messages.enumerated().compactMap { index, msg -> ChatMessage? in
            // PendingMessage does not expose message_number, but its timestamp is the server's
            // receive timestamp (not the sender's wall clock) and the response is already sorted
            // by the server's mailbox order. Use the page index only as a same-millisecond tie
            // breaker; a later live-stream envelope will replace this fallback with its exact key.
            let serverOrderKey: String? = {
                let milliseconds = msg.timestamp.multipliedReportingOverflow(by: 1_000)
                guard msg.timestamp > 0, !milliseconds.overflow else {
                    return nil
                }
                return ServerMessageOrder.key(
                    serverTimestampMilliseconds: milliseconds.partialValue,
                    sequence: UInt64(index)
                )
            }()
            // SESSION_RESET_INIT: identified path — sealed deliveries use the generic path below.
            if msg.contentType == .sessionResetInit {
                let message = ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    timestamp: UInt64(msg.timestamp),
                    serverOrderKey: serverOrderKey,
                    contentType: 24,
                    rawPayload: msg.encryptedPayload
                )
                guard message.wire != nil else {
                    Log.debug("Failed to decode SESSION_RESET_INIT payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                Log.debug("SESSION_RESET_INIT pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return message
            }
            // END_SESSION: contentType is the sole classifier (size heuristic removed).
            if msg.contentType == .sessionReset {
                Log.debug("END_SESSION pending from \(msg.senderID.prefix(8))… id=\(msg.messageID.prefix(8))…", category: "MessagingServiceClient")
                return ChatMessage(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    timestamp: UInt64(msg.timestamp),
                    serverOrderKey: serverOrderKey,
                    contentType: 21,
                    rawPayload: msg.encryptedPayload
                )
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session.
            // PendingMessage carries no senderDevice/conversationID; the copy's certificate names
            // the sibling, and the partner travels inside the ciphertext (`SenderSyncRouting`).
            if msg.contentType == .senderSync {
                guard let message = OwnDeviceCopy.message(
                    id: msg.messageID,
                    from: msg.senderID,
                    to: "",
                    timestamp: UInt64(msg.timestamp),
                    serverOrderKey: serverOrderKey,
                    conversationId: "",
                    payload: msg.encryptedPayload
                ) else {
                    Log.debug("Failed to decode SENDER_SYNC payload \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                    failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                    return nil
                }
                return message
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
            let message = ChatMessage(
                id: msg.messageID,
                from: isSealed ? "" : msg.senderID,
                to: "",
                timestamp: UInt64(msg.timestamp),
                serverOrderKey: serverOrderKey,
                contentType: UInt8(clamping: msg.contentType.rawValue),
                rawPayload: wirePayload,
                sealedInnerData: sealedInner
            )
            // A sealed control's inner need not be a wire payload (the payload is kept so its
            // SessionControl reason survives unseal); anything else must be one.
            guard message.wire != nil || isSealed else {
                Log.debug("Failed to decode encrypted_payload for message \(msg.messageID) — queuing failed ACK", category: "MessagingServiceClient")
                failed.append(FailedMessage(id: msg.messageID, senderId: msg.senderID))
                return nil
            }
            return message
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
