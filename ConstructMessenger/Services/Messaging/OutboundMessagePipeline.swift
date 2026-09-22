import CoreData
import Foundation

/// In-memory map from server-assigned wire message ids to the sender's local message ids.
/// On the sealed-sender path the server reassigns every message id (it must not trust a
/// client-chosen id), so server-side delivery receipts arrive with ids the sender never
/// stored. Recording the sendMessage response id lets receipt handling find the local row.
/// Best-effort: not persisted — E2E receipts (which carry the canonical E2E id) cover the
/// post-restart case.
final class ServerMessageIdMap: @unchecked Sendable {
    static let shared = ServerMessageIdMap()

    private let lock = NSLock()
    private var serverToLocal: [String: String] = [:]
    private var insertionOrder: [String] = []
    private let capacity = 512

    private init() {}

    func record(serverId: String, localId: String) {
        let server = serverId.lowercased()
        let local = localId.lowercased()
        guard !server.isEmpty, server != local else { return }
        lock.lock()
        defer { lock.unlock() }
        if serverToLocal[server] == nil {
            insertionOrder.append(server)
            if insertionOrder.count > capacity {
                serverToLocal.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        serverToLocal[server] = local
    }

    /// Returns the local id for a (possibly server-assigned) id; identity when unknown.
    func localId(for id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return serverToLocal[id.lowercased()] ?? id
    }
}

/// What one send to one person left behind, device by device.
///
/// The row the user is looking at has one status, and a person has N devices, so the two are
/// related by a fold — `status` — and the devices the fold left out are named apart in `owed`,
/// because "the message is in their mailbox" and "every device of theirs can open it" are
/// different facts with different remedies: the first is the row's, the second is
/// `FanoutRetryQueue`'s.
struct RecipientSendReport {

    /// One device's copy: the server's answer folded over its chunks, or the error that stopped
    /// it. Exactly one of the two is set.
    struct Copy {
        let deviceId: String
        let response: SendMessageResponse?
        let error: Error?

        /// The server took every chunk of this copy.
        var accepted: Bool {
            guard let response else { return false }
            switch response.status.lowercased() {
            case "failed", "queued", "blocked": return false
            default: return true
            }
        }
    }

    let copies: [Copy]
    /// The fold the callers switch on, in the shape the single send used to return: `sent` when
    /// at least one device's copy was accepted in full — the message is in the person's mailbox,
    /// which is what that status has always meant — otherwise the worst of what the devices
    /// answered, with the longest `retryAfterMs` and the first error code.
    let status: SendMessageResponse
    /// Devices that did not get their copy and could still: a transport error, a retryable
    /// refusal. Not devices whose refusal was final — those are not owed, they are lost, and
    /// the log says which.
    let owed: [String]

    var accepted: [String] { copies.filter(\.accepted).map(\.deviceId) }
}

/// The one way a message reaches the devices of the person it is for.
///
/// ## There is no primary send
///
/// Until 2026-09-22 there were two: the ordinary send encrypted to the session the recipient's
/// *pinned* key named, sealed to that key, and its answer was the row's status; a fan-out then
/// reached every *other* device from a bundle fetch, with its own session rule, its own seal key,
/// no privacy-pass recovery, no retry store, no server-id map and no status. The second device of
/// anyone was a second-class recipient, and the client could not say which device a message had
/// not reached. See `sessions/2026-09-22-one-send-n-devices.md` and
/// `decisions/a-peer-is-a-set-of-devices.md`, item 1.
///
/// Now one function sends one copy to one device, with everything the ordinary send had, and
/// `sendToRecipientDevices` loops it over the plan. The plan is the core's
/// (`DeviceDeliveryPlan.targets`); the device set is the local one (`PeerDevice`), so a send to a
/// peer we hold sessions with never waits on the key server, and a bundle is fetched only for a
/// device that has no session yet — which is the one moment a one-time pre-key is spent.
///
/// ## What is deliberately unchanged
///
/// Session *establishment*. Callers still gate on `CryptoManager.hasSession(for: account)` — a
/// session with the pinned device — and hand a peer without one to the handshake; a device
/// found here without a session is opened from its bundle, as the fan-out always did. Which
/// devices a send must hold sessions with, and who opens them, is the machine's question
/// (`decisions/session-is-one-state-machine.md`) and is not answered by moving the loop.
@MainActor
final class OutboundMessagePipeline {
    static let shared = OutboundMessagePipeline()

    private init() {}

    /// What is being sent, which decides what the send is owed afterwards.
    enum Kind {
        /// A message with a row: retained for retry, mapped for server receipts, owed to every
        /// device of the recipient — one without a session gets one opened from its bundle.
        case message
        /// A control carrier with no row — a delivery receipt, the intake key. Best-effort, as
        /// these always were: nothing retained, nothing queued, and sent only to the devices we
        /// already hold a session with. Opening a session to deliver a checkmark would spend a
        /// one-time pre-key and start a handshake for a claim the next message repeats anyway;
        /// a sibling without a session gets nothing, which is what every device but the pinned
        /// one got before 2026-09-22.
        case control
    }

    /// Send `plan` to every device of `recipientId`, or to `onlyDevices` of them.
    ///
    /// Throws only for what stops the whole send before any device is tried, or what stopped
    /// every device the same way: no device is known for the peer, the sender certificate could
    /// not be built (`StealthDowngradeBlocked`, which callers queue on), a transport error that
    /// every copy hit. A failure on one device while another succeeded is in the report, not
    /// thrown — the message went, and the device is owed.
    func sendToRecipientDevices(
        plan: ChunkedMessagePlan,
        baseMessageId: String,
        senderId: String,
        recipientId: String,
        timestamp: UInt64,
        kind: Kind = .message,
        spendUnit callerSpendUnit: TokenSpendUnit? = nil,
        onlyDevices: [String]? = nil
    ) async throws -> RecipientSendReport {
        if kind == .message {
            // Anything owed to this recipient rides out with the message instead of waiting for
            // the receipt grid. Receipts are the only traffic this client emits as a reflex to
            // someone else's action; next to a send the user just made they are timed by the user
            // instead. A control does not carry them — a receipt is itself one, and would re-enter.
            DeliveryReceiptBatcher.shared.flushPiggyback(to: recipientId)
        }

        let stealthOn = StealthPolicy.shared.shouldUseSealedSender()
        var targets = try await recipientTargets(for: recipientId, stealthOn: stealthOn)
        if kind == .control {
            targets = targets.filter { CryptoManager.shared.hasSession(for: $0.deviceId) }
            guard !targets.isEmpty else {
                Log.debug("Outbound: control \(baseMessageId.prefix(8))… to \(recipientId.prefix(8))… — no device with a session", category: "Outbound")
                return RecipientSendReport(copies: [], status: SendMessageResponse(messageId: baseMessageId, status: "sent"), owed: [])
            }
        }
        let planned = onlyDevices.map { owed in targets.filter { owed.contains($0.deviceId) } } ?? targets
        guard !planned.isEmpty else {
            // A retry narrowed to devices that are no longer in the set — revoked, or pruned by a
            // later bundle answer. Nothing to send and nothing owed.
            Log.info(
                "Outbound: no device of \(recipientId.prefix(8))… left to send \(baseMessageId.prefix(8))… to" +
                (onlyDevices.map { " (\($0.count) owed, none still known)" } ?? ""),
                category: "Outbound"
            )
            return RecipientSendReport(
                copies: [],
                status: SendMessageResponse(messageId: baseMessageId, status: "sent"),
                owed: []
            )
        }

        // One Privacy Pass spend for the whole logical message, across every device and every
        // chunk. The unit of spend is a message to a **person**, and `token_spend_id` is bound to
        // `recipient_user_id`, so N copies to one recipient are covered once. Paying per envelope
        // would multiply a three-photo album by the recipient's device count and empty a young
        // account's hourly allowance on one tap. A caller's unit wins — a retry rides on the
        // redemption the first send opened.
        let spendUnit: TokenSpendUnit?
        if let callerSpendUnit {
            spendUnit = callerSpendUnit
        } else {
            spendUnit = TokenSpendUnit.forEnvelopeCount(
                TokenSpendUnit.envelopeCount(chunkCount: plan.payloads.count, recipientDeviceCount: planned.count)
            )
        }

        // The tag replaces the device id in the wire id, so the relay routes a copy it cannot
        // attribute to a device. Absent only before registration — and then there is nothing to
        // send as.
        let ourIdentityPrivate = KeychainManager.shared.loadDeviceIdentityKey()

        var copies: [RecipientSendReport.Copy] = []
        for target in planned {
            do {
                let response = try await sendCopy(
                    to: target,
                    plan: plan,
                    baseMessageId: baseMessageId,
                    senderId: senderId,
                    recipientId: recipientId,
                    timestamp: timestamp,
                    kind: kind,
                    stealthOn: stealthOn,
                    spendUnit: spendUnit,
                    ourIdentityPrivate: ourIdentityPrivate
                )
                copies.append(.init(deviceId: target.deviceId, response: response, error: nil))
            } catch let blocked as StealthDowngradeBlocked {
                // Ours to fix, not the device's: the sender certificate. Every copy would fail the
                // same way, and the callers' answer to it is to queue the whole message.
                throw blocked
            } catch {
                // One device's failure says nothing about the next one's session or transport, so
                // the loop is not cut short. A partial multi-chunk copy never reassembles, so a
                // chunk that failed owes the device the whole message — `sendCopy` stops at the
                // first failed chunk for that reason.
                Log.error(
                    "Outbound: copy of \(baseMessageId.prefix(8))… for \(target.deviceId.prefix(8))… failed: \(error)",
                    category: "Outbound"
                )
                copies.append(.init(deviceId: target.deviceId, response: nil, error: error))
            }
        }

        let report = Self.fold(copies, baseMessageId: baseMessageId)
        guard kind == .message else { return report }
        // The §C gate: a device of the recipient did not get its copy of a message the sender
        // will consider sent. Counted per device, here, because this is now the only place a
        // recipient device is reached and the only place its loss is known.
        for copy in report.copies where !copy.accepted {
            PerformanceMetrics.shared.record(.fanoutDeviceSkipped, label: "send_failed")
        }
        // Nothing went and every device threw: the callers' catch blocks classify a thrown error
        // — transport failure versus everything else — so it is thrown as the send's rather than
        // folded into a status they would read as a server refusal.
        if report.accepted.isEmpty, let error = report.copies.first?.error,
           report.copies.allSatisfy({ $0.error != nil }) {
            throw error
        }
        if !report.accepted.isEmpty {
            // The message went. What did not reach every device is the retry queue's — and a
            // message that reached all of them clears an entry an earlier attempt may have left,
            // or the queue would re-send a message that has already arrived.
            if report.owed.isEmpty {
                FanoutRetryQueue.shared.remove(key: "\(baseMessageId)|\(recipientId)")
            } else {
                // A no-op while the drain runs: it holds the entry and narrows it from the report.
                MultiDeviceSendCoordinator.shared.noteOwed(baseMessageId, recipientId, senderId, owed: report.owed)
            }
        }
        return report
    }

    // MARK: - The device set

    /// The recipient's devices as targets, from the local set.
    ///
    /// Falls back to the pinned key for a peer recorded before `PeerDevice` existed, and refuses
    /// — fail closed under stealth, as the seal key's absence always did — for a peer we hold no
    /// key for at all: nothing can be encrypted to and nothing sealed.
    private func recipientTargets(for recipientId: String, stealthOn: Bool) async throws -> [DeviceDeliveryTarget] {
        let context = PersistenceController.shared.container.viewContext
        let local = SessionAddressing.devices(ofPeer: recipientId, in: context).map {
            PlannedRecipientDevice(deviceId: $0.deviceId, identityPublic: $0.identityKey)
        }
        // Free when it is there, never fetched for: the plan is built from what we hold, and the
        // directory only adds what it already knows.
        var devices = PlannedRecipientDevice.merge(
            local: local,
            directory: MultiDeviceSendCoordinator.shared.knownRecipientDevices(for: recipientId) ?? []
        )
        if devices.isEmpty {
            // Nothing pinned and nothing cached: this is a first send, and the one thing we must
            // not do is guess a single device. Until 2026-09-22 the plan fell straight through to
            // the pinned key — one device — and the directory was consulted afterwards, by
            // `ensureSession`, for the device already planned; so the first message to a peer
            // reached one of their devices and every message after it reached all of them.
            let fetched = try? await MultiDeviceSendCoordinator.shared.recipientBundles(for: recipientId)
            devices = (fetched ?? []).map(PlannedRecipientDevice.init)
        }
        if devices.isEmpty,
           let pinned = SessionAddressing.pinnedIdentityKey(ofUser: recipientId),
           let pinnedDevice = SessionAddressing.cryptoIdentity(ofIdentityKey: pinned) {
            // The offline answer, and only that: the key server was asked and did not answer.
            devices = [PlannedRecipientDevice(deviceId: pinnedDevice, identityPublic: pinned)]
        }
        guard !devices.isEmpty else {
            let reason = "no known device for \(recipientId.prefix(8))…"
            if stealthOn { throw StealthDowngradeBlocked(reason: reason) }
            Log.error("Outbound: \(reason)", category: "Outbound")
            throw CryptoManagerError.sessionNotFound
        }
        return DeviceDeliveryPlan.targets(
            recipientDevices: devices,
            ownDevices: [],
            ourDeviceId: AuthSessionManager.shared.currentDeviceId,
            recipientIsSelf: false
        )
    }

    /// A session with `target`, opening one from its bundle when there is none.
    ///
    /// The bundle comes with the target when a fetch produced it, and is fetched — through the
    /// coordinator's cache, so a conversation does not exhaust `BUNDLE_RATE_LIMIT_PER_MIN` —
    /// only now, for a device that has none. Never clobbers a session that exists.
    private func ensureSession(with target: DeviceDeliveryTarget, recipientId: String) async throws {
        guard !CryptoManager.shared.hasSession(for: target.deviceId) else { return }
        let bundle: PublicKeyBundleData
        if let carried = target.bundle {
            bundle = carried
        } else {
            let fetched = try await MultiDeviceSendCoordinator.shared.recipientBundles(for: recipientId)
            guard let match = fetched.first(where: { $0.deviceId == target.deviceId }) else {
                throw CryptoManagerError.sessionNotFound
            }
            bundle = match.bundle
        }
        do {
            _ = try SessionInitializationService.shared.initializeSession(
                userId: target.deviceId, bundle: bundle, deleteExisting: false
            )
        } catch SessionError.peerSPKStale {
            // Offline too long to rotate its SPK — degrade rather than drop the copy. Flags the
            // session at-risk (see stale-peer-reachability).
            _ = try SessionInitializationService.shared.initializeSession(
                userId: target.deviceId, bundle: bundle, deleteExisting: false, allowStale: true
            )
        }
    }

    // MARK: - One copy

    /// Every chunk of `plan` to one device: encrypt to its ratchet, seal to its key, send under a
    /// wire id that names it to nobody but itself.
    private func sendCopy(
        to target: DeviceDeliveryTarget,
        plan: ChunkedMessagePlan,
        baseMessageId: String,
        senderId: String,
        recipientId: String,
        timestamp: UInt64,
        kind: Kind,
        stealthOn: Bool,
        spendUnit: TokenSpendUnit?,
        ourIdentityPrivate: Data?
    ) async throws -> SendMessageResponse {
        try await ensureSession(with: target, recipientId: recipientId)

        let tag = MultiDeviceSendCoordinator.senderSyncTag(
            baseMessageId: baseMessageId,
            targetDeviceId: target.deviceId,
            targetIdentityPublic: target.identityPublic,
            ourIdentityPrivateKey: ourIdentityPrivate
        )

        var responses: [SendMessageResponse] = []
        for (index, payload) in plan.payloads.enumerated() {
            let chunkMessageId = DeviceDeliveryPlan.wireId(
                baseMessageId: baseMessageId, tag: tag, audience: target.audience,
                chunkIndex: index, chunkCount: plan.payloads.count
            )

            // All encryption goes through the Rust orchestrator — PQXDH, DR state and wire-payload
            // packing are handled inside handleEvent(.outgoingMessage). Addressed by device: the
            // seam passes a device id through unchanged.
            let encryptedPayload = try OutboundSessionService.shared.encryptOutgoing(
                plaintext: payload,
                messageId: chunkMessageId,
                recipientId: target.deviceId
            )
            if kind == .message {
                OutgoingWirePayloadStore.shared.saveChunk(
                    baseMessageId: baseMessageId,
                    chunkMessageId: chunkMessageId,
                    wirePayload: encryptedPayload,
                    recipientDeviceId: target.deviceId
                )
            }

            let response = try await Self.sendEncrypted(
                encryptedPayload,
                chunkMessageId: chunkMessageId,
                baseMessageId: baseMessageId,
                senderId: senderId,
                recipientId: recipientId,
                recipientDeviceId: target.deviceId,
                recipientIdentityKey: target.identityPublic,
                timestamp: timestamp,
                stealthOn: stealthOn,
                spendUnit: spendUnit
            )
            responses.append(response)

            // Sealed path: the server reassigns wire ids — remember them so server-side delivery
            // receipts can be matched back to the local message row. A control has no row.
            if kind == .message, !response.messageId.isEmpty {
                ServerMessageIdMap.shared.record(serverId: response.messageId, localId: baseMessageId)
            }
            // A partial set never reassembles, so a refused chunk owes the device the whole
            // message; the remaining chunks would be ratchet advances for nothing.
            if !RecipientSendReport.Copy(deviceId: target.deviceId, response: response, error: nil).accepted {
                break
            }

            if index < plan.payloads.count - 1 {
                let jitterMs = UInt64.random(in: ChunkedDeliveryConfig.chunkSendJitterMinMs...ChunkedDeliveryConfig.chunkSendJitterMaxMs)
                try await Task.sleep(nanoseconds: jitterMs * 1_000_000)
            }
        }
        CryptoManager.shared.saveSessionToKeychain(for: target.deviceId)
        return Self.aggregate(responses: responses, baseMessageId: baseMessageId)
    }

    /// One ciphertext to one device: sealed when stealth is on, identified only when it is off.
    ///
    /// Under stealth-on, sealing is MANDATORY. If the seal cannot be built (sender certificate
    /// unavailable) this must NOT fall back to an identified send — that is the server-influence
    /// deanonymisation vector the sealed path exists to prevent. Fails closed with
    /// `StealthDowngradeBlocked` so the caller queues and retries.
    ///
    /// Also the retry manager's reseal: a stored ciphertext is re-sent through here with the
    /// device it was encrypted for, and the ratchet does not advance.
    static func sendEncrypted(
        _ encryptedPayload: Data,
        chunkMessageId: String,
        baseMessageId: String,
        senderId: String,
        recipientId: String,
        recipientDeviceId: String,
        recipientIdentityKey: Data,
        timestamp: UInt64,
        stealthOn: Bool,
        spendUnit: TokenSpendUnit?
    ) async throws -> SendMessageResponse {
        guard stealthOn else {
            // Reached ONLY when stealth is off (DEBUG override / feature disabled). The chokepoint
            // refuses this branch whenever stealth is on.
            return try await MessagingServiceClient.shared.sendMessage(
                messageId: chunkMessageId,
                recipientId: recipientId,
                senderId: senderId,
                conversationId: "",
                encryptedPayload: encryptedPayload,
                timestamp: timestamp,
                recipientDeviceId: recipientDeviceId,
                sealing: .identified(.stealthDisabled)
            )
        }

        let sealedInner: Data
        do {
            sealedInner = try await StealthSenderService.buildSealedInner(
                recipientUserId: recipientId,
                recipientIdentityKey: recipientIdentityKey,
                encryptedPayload: encryptedPayload,
                // Generic on purpose: under a seal the baseline is the field's absence, and the
                // real type rides in KNST byte 5 inside the ciphertext.
                contentType: .generic,
                spendUnit: spendUnit
            )
        } catch {
            Log.error("STEALTH: seal failed under stealth-on — refusing identified downgrade, queueing: \(error)", category: "Outbound")
            PerformanceMetrics.shared.record(.stealthSealFailure, label: "chunked")
            throw StealthDowngradeBlocked(reason: "seal failed: \(error)")
        }

        // Sealed path with one-shot enforce recovery: on a privacy_pass rejection the wallet is
        // force-replenished and the SealedInner rebuilt (fresh token + delivery tag; the DR
        // payload is reused — the ratchet does not advance). Never downgrades to an identified
        // send (StealthSendRecovery invariant).
        return try await StealthSendRecovery.sendSealed(sealedInner, rebuild: { afterCredentialRejection in
            // A privacy_pass rejection means the redemption we were counting on did not happen —
            // so the rebuilt envelope has to pay again. Without this the rebuild would re-attach
            // the same unpaid spend id and be rejected identically. The stored id goes too, or the
            // next retry of this message would rebuild from the store and be rejected the same
            // way, turning a one-shot recovery into a loop; on a first send there is nothing
            // stored yet and this is a no-op.
            spendUnit?.invalidatePayment()
            TokenSpendUnitStore.forget(baseMessageId: baseMessageId, recipientId: recipientId)
            return try await StealthSenderService.buildSealedInner(
                recipientUserId: recipientId,
                recipientIdentityKey: recipientIdentityKey,
                encryptedPayload: encryptedPayload,
                contentType: .generic,
                spendUnit: spendUnit,
                afterCredentialRejection: afterCredentialRejection
            )
        }, send: { inner in
            if FeatureFlags.sealedSenderUnauthenticatedTransport {
                // stealth-sealed-sender-v2 Phase 2: dedicated unauthenticated RPC/channel.
                return try await MessagingServiceClient.shared.sendSealedMessage(sealedInner: inner)
            } else {
                // `conversation_id` stays empty: it would name the person on the other side in
                // the clear, and nothing on the server reads it. The sealed branch of
                // `buildEnvelope` writes neither it nor `recipient_device` — the device is derived
                // from the key the seal was built against, so "who can open this" and "where does
                // it go" stay one value.
                return try await MessagingServiceClient.shared.sendMessage(
                    messageId: chunkMessageId,
                    recipientId: recipientId,
                    senderId: senderId,
                    conversationId: "",
                    encryptedPayload: encryptedPayload,
                    timestamp: timestamp,
                    recipientDeviceId: recipientDeviceId,
                    sealing: .sealed(inner)
                )
            }
        })
    }

    // MARK: - Folds

    /// The row's answer from the devices' answers. Pure, so a test can hold it to its rule.
    nonisolated static func fold(_ copies: [RecipientSendReport.Copy], baseMessageId: String) -> RecipientSendReport {
        let accepted = copies.filter(\.accepted)
        if let best = accepted.compactMap(\.response).first {
            // The message is in the mailbox. Devices that were not reached are owed unless their
            // refusal was final; the row does not wait on them.
            let owed = copies.filter { !$0.accepted }.filter { copy in
                copy.error != nil || (copy.response?.retryable ?? false)
            }.map(\.deviceId)
            let ordered = accepted.compactMap(\.response)
                .filter { $0.serverOrderKey != nil }
                .min { ($0.serverOrderKey ?? "") < ($1.serverOrderKey ?? "") }
            let status = SendMessageResponse(
                messageId: baseMessageId,
                status: best.status,
                messageNumber: ordered?.messageNumber ?? 0,
                serverTimestamp: ordered?.serverTimestamp ?? 0,
                retryable: true,
                errorCode: "",
                retryAfterMs: 0,
                attemptId: best.attemptId
            )
            return RecipientSendReport(copies: copies, status: status, owed: owed)
        }
        // Nothing went. Server refusals fold as the single send's did; a device that threw is
        // a retryable failure with no server answer to fold, so it only contributes to `owed`
        // (and `sendToRecipientDevices` throws instead when every device threw).
        let responses = copies.compactMap(\.response)
        let folded = responses.isEmpty
            ? SendMessageResponse(messageId: baseMessageId, status: "failed", retryable: true)
            : aggregate(responses: responses, baseMessageId: baseMessageId)
        let owed = copies.filter { $0.error != nil || ($0.response?.retryable ?? false) }.map(\.deviceId)
        return RecipientSendReport(copies: copies, status: folded, owed: owed)
    }

    /// The single-send fold over chunks, unchanged: one failed chunk fails the copy.
    nonisolated static func aggregate(responses: [SendMessageResponse], baseMessageId: String) -> SendMessageResponse {
        var status = "sent"
        var retryable = true
        var errorCode = ""
        var retryAfterMs: Int64 = 0
        var attemptId = ""
        let firstServerOrderedResponse = responses
            .filter { $0.serverOrderKey != nil }
            .min { ($0.serverOrderKey ?? "") < ($1.serverOrderKey ?? "") }
        for r in responses {
            let st = r.status.lowercased()
            if st == "failed" || st == "blocked" {
                status = st
                retryable = retryable && r.retryable
            } else if st == "queued", status != "failed", status != "blocked" {
                status = "queued"
                retryable = retryable && r.retryable
            } else if st == "delivered", status == "sent" {
                status = "delivered"
                retryable = retryable && r.retryable
            } else {
                retryable = retryable && r.retryable
            }
            // Propagate first non-empty error code
            if errorCode.isEmpty, !r.errorCode.isEmpty {
                errorCode = r.errorCode
            }
            if attemptId.isEmpty, !r.attemptId.isEmpty {
                attemptId = r.attemptId
            }
            // Use the longest retry-after hint from all chunks
            if r.retryAfterMs > retryAfterMs {
                retryAfterMs = r.retryAfterMs
            }
        }
        return SendMessageResponse(
            messageId: baseMessageId,
            status: status,
            messageNumber: firstServerOrderedResponse?.messageNumber ?? 0,
            serverTimestamp: firstServerOrderedResponse?.serverTimestamp ?? 0,
            retryable: retryable,
            errorCode: errorCode,
            retryAfterMs: retryAfterMs,
            attemptId: attemptId
        )
    }
}
