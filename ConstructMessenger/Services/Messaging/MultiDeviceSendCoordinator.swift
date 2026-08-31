//
//  MultiDeviceSendCoordinator.swift
//  Construct Messenger
//
//  Handles multi-device message fan-out and SenderSync.
//
//  Overview
//  ────────
//  After the primary message send (handled by ChunkedMessageSender), this coordinator:
//  1. Fan-out  — sends to all OTHER recipient devices (if they have bundles on the server).
//  2. SenderSync — sends a copy to the sender's own other devices so conversation history
//     stays in sync. The server-side content type is SENDER_SYNC (= 23), which the
//     receiving device displays as an outgoing bubble in the same conversation.
//
//  Session key convention
//  ──────────────────────
//  A session's contactId is a `CryptoDeviceId` — the 32-hex id derived from the peer device's
//  identity key. Every send below already holds one (`target.deviceId`) and passes it straight
//  down; nothing here composes a key out of two parts, and the account id travels separately as
//  `networkRecipientUserId` because it addresses the mailbox, not the ratchet.
//
//  It used to be a bare `userId` for the primary session and `userId:deviceId` for per-device
//  ones — two spellings of one thing, the first of which named an account to a layer that only
//  understands devices. `SessionAddressing` is the single seam now and everything below it is a
//  device id (`decisions/identity-is-a-set-of-keys.md`). The colon shape survives only as a
//  legacy Keychain account name the wipe must still recognise, in
//  `KeychainSessionAccounts.isIdentityShaped` — no code writes one.
//
//  Threading
//  ─────────
//  @MainActor — CryptoManager and SessionInitializationService both require main-actor
//  access. Fire-and-forget via a detached Task where callers are already on MainActor.
//

import Foundation
import CoreData
import CryptoKit

/// What a fan-out attempt left behind.
///
/// Returned so the retry drain can narrow the entry it is holding to exactly what this attempt
/// lost. Without it a re-plan that reached one device and lost another would stay a re-plan, and
/// the next pass would send the first device a second ciphertext of the same message.
enum FanoutOutcome: Equatable {
    /// Every device the plan named has its copy — or the plan named none, which for a
    /// single-device recipient is the ordinary answer.
    case complete
    /// These devices still need it. Never empty; `replan` is the empty case, and the two mean
    /// different things to the next attempt.
    case owed([String])
    /// Nothing was sent, and nothing can name the devices — the bundle fetch is what failed. The
    /// next attempt starts from a fresh plan.
    case replan
    /// Not a transport failure and not worth retrying: no sender device id, or no chunks.
    case notRetryable
}

@MainActor
final class MultiDeviceSendCoordinator {

    static let shared = MultiDeviceSendCoordinator()
    private init() {}

    // MARK: - Own-device bundle cache

    private struct DeviceCache {
        var bundles: [DeviceBundleData]
        var fetchedAt: Date
    }
    private var ownDeviceCache: DeviceCache?
    private let cacheTTL: TimeInterval = 3600 // 1 hour

    /// True while `drainRetryQueue` is running, so a failing retry re-uses its entry instead of
    /// appending a second one. Safe as a plain `Bool` because the class is `@MainActor` and the
    /// drain never suspends between reading it and clearing it in a `defer`.
    private var isDraining = false

    /// Invalidate the own-device cache (call after linking or revoking a device).
    func invalidateOwnDeviceCache() {
        ownDeviceCache = nil
    }

    // MARK: - Public API

    /// Our own other devices, as far as this process currently knows — cache only, never a fetch.
    ///
    /// Used by the SENDER_SYNC receive path to decide which sessions to try and to derive the
    /// tag secrets. It must not go to the network: an incoming message is being routed, and the
    /// answer is needed now. An empty result simply means the primary session is the only
    /// candidate, which is the state a single-device account is in permanently. The cache fills on
    /// the first send that fans out.
    func knownOwnDevices(myUserId: String) -> [DeviceBundleData] {
        guard let cache = ownDeviceCache,
              Date().timeIntervalSince(cache.fetchedAt) < cacheTTL else { return [] }
        return cache.bundles
    }

    func knownOwnDeviceIds(myUserId: String) -> [String] {
        knownOwnDevices(myUserId: myUserId).map(\.deviceId)
    }

    /// Fill the own-device cache from the server, for the **receive** path.
    ///
    /// Until 2026-08-18 the cache had exactly one filler — the send path — so a device that had
    /// linked and not yet sent anything knew of no siblings at all. A SENDER_SYNC copy then had no
    /// candidate session to try, no device id to fetch a bundle for, and
    /// `handleUnopenedSenderSync` walked a list of one entry that carried no `:` and returned
    /// having done nothing and logged nothing. Observed on the two-simulator stand 2026-08-17: a
    /// freshly linked device received both copies and neither reached the transcript.
    ///
    /// Not a hot-path call: the receive side reaches for it only when it has no siblings on record
    /// **and** a copy from one has just arrived, which is once per device lifetime in the ordinary
    /// case. Never burns a one-time pre-key — these are our own devices.
    @discardableResult
    func refreshOwnDevices(myUserId: String) async -> [DeviceBundleData] {
        do {
            let all = try await KeyServiceClient.shared.getPreKeyBundles(
                userId: myUserId, consumeOneTimePrekey: false
            )
            ownDeviceCache = DeviceCache(bundles: all, fetchedAt: Date())
            Log.info(
                "MultiDevice: own-device list refreshed on the receive path — \(all.count) device(s)",
                category: "MultiDevice"
            )
            return all
        } catch {
            Log.error(
                "MultiDevice: own-device refresh failed for \(myUserId.prefix(8))…: \(error)",
                category: "MultiDevice"
            )
            return []
        }
    }

    /// Identity keys of our other devices, for reading the `-ss-<tag>` on an incoming copy.
    ///
    /// Public halves, not derived secrets: the pair secret is computed inside the core, one X25519
    /// per known device per message. Not cached there either — an account has units of devices, and
    /// a cache of derived key material is state that has to be invalidated when a device is
    /// revoked, a correctness risk out of proportion to ~50µs.
    func senderSyncPeerIdentityKeys(myUserId: String) -> [Data] {
        let myDeviceId = AuthSessionManager.shared.currentDeviceId
        return knownOwnDevices(myUserId: myUserId)
            .filter { $0.deviceId != myDeviceId }
            .map(\.bundle.identityPublic)
    }

    /// Our own identity private key — the other half of every pair secret above.
    ///
    /// Absent only before registration completes, and then there are no own devices to sync to.
    func ourIdentityPrivateKey() -> Data? {
        KeychainManager.shared.loadDeviceIdentityKey()
    }

    /// The tag for a copy addressed to `targetDeviceId`, or the legacy plain-hex prefix when the
    /// key material to compute one is missing.
    ///
    /// The fallback keeps a copy deliverable to a peer that would otherwise get an unreadable tag;
    /// it costs the same metadata the whole change removes, so it is logged rather than silent.
    static func senderSyncTag(
        baseMessageId: String,
        targetDeviceId: String,
        targetIdentityPublic: Data,
        ourIdentityPrivateKey: Data?
    ) -> String {
        guard let ourIdentityPrivateKey,
              let tag = SenderSyncDeviceTag.tag(
                  baseMessageId: baseMessageId,
                  targetDeviceId: targetDeviceId,
                  ourIdentityPrivateKey: ourIdentityPrivateKey,
                  peerIdentityPublicKey: targetIdentityPublic
              ) else {
            Log.error(
                "SenderSync: no pair secret for \(targetDeviceId.prefix(8))… — falling back to the plain device tag, which the relay can read",
                category: "MultiDevice"
            )
            return String(targetDeviceId.prefix(SenderSyncDeviceTag.legacyHexLength))
        }
        return tag
    }

    /// Fan-out: send `plaintext` to ALL of the recipient's devices.
    ///
    /// Intended for use after the primary send (which already covers the recipient's
    /// Everyone besides the recipient's primary device who must learn of this message:
    /// the sender's own other devices, and the recipient's other devices.
    ///
    /// **The single answer to that question.** It had two callers and two answers until
    /// 2026-08-30: `ChatSendCoordinator` ran both halves after a successful first attempt, and
    /// `MessageRetryManager` ran neither. A message that failed its first send and succeeded on
    /// retry therefore reached exactly one device, permanently, while the sender's UI said sent.
    /// Measured on a three-device run that day: fifteen sends, two mirrored.
    ///
    /// Nothing reported it. The mirror is best-effort by design, so its absence and its failure
    /// look identical from the outside, and the devices that never learn of the message have
    /// nothing to notice.
    ///
    /// - Parameters:
    ///   - wirePlaintext: pre-KNST `MessageContent` bytes — what SenderSync re-frames per own
    ///     device. Not display JSON (see local-message-payload-binary.md C1c).
    ///   - chunks: the **same** KNST payloads the primary send used, so the recipient's other
    ///     devices see one framing of one message.
    func mirrorOutgoing(
        wirePlaintext: Data,
        chunks: [Data],
        messageId: String,
        recipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        timestamp: UInt64
    ) async {
        await sendSenderSync(
            plaintext: wirePlaintext,
            messageId: messageId,
            originalRecipientUserId: recipientUserId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp
        )
        // Discarded here on purpose: on a first attempt the function has already queued whatever
        // it owes. The outcome exists for the drain, which is holding an entry it must narrow
        // rather than add to.
        _ = await fanOutToRecipientDevices(
            chunks: chunks,
            messageId: messageId,
            recipientUserId: recipientUserId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp
        )
    }

    /// default device via the plain `userId` session). Each device gets its own
    /// E2EE session keyed by `recipientUserId:deviceId`.
    ///
    /// Errors per-device are logged and skipped; the function never throws.
    ///
    /// `chunks` are the **same KNST payloads the primary send used**, not the raw plaintext. The
    /// copies differ from the primary send only in which session encrypts them, so rebuilding a
    /// plan here would be a second framing of one message — and it used to be worse than that:
    /// this path sent the plaintext in a single shot with `chunkCount: 1`, so any message that
    /// needed chunking arrived at the peer's other devices as one oversized frame nothing could
    /// reassemble. It had no caller, so nobody saw it.
    func fanOutToRecipientDevices(
        chunks: [Data],
        messageId: String,
        recipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        timestamp: UInt64,
        onlyDevices: [String]? = nil
    ) async -> FanoutOutcome {
        // Four ways out of this function, three of them silent until 2026-08-30. A skipped
        // device is not visible anywhere else: the message is delivered, the sender sees "sent",
        // and only a device that never heard of it could tell — which it cannot. So each exit
        // says which one it was, and — where a retry could help — leaves an entry naming what is
        // still owed.
        //
        // These first two do not: without a sender device id there is no tag to compute and no
        // identity to send as, and empty chunks mean the caller framed nothing. Neither is a
        // transport failure, so neither is retryable; queueing them would be a queue that drains
        // into the same wall every thirty seconds.
        guard !senderDeviceId.isEmpty, !chunks.isEmpty else {
            await recordSkip(
                senderDeviceId.isEmpty ? "no_sender_device" : "no_chunks",
                peer: recipientUserId
            )
            return .notRetryable
        }
        do {
            // Per-device fan-out to a recipient: a device we have no session with yet needs
            // X3DH, so this fetch legitimately consumes a one-time pre-key.
            let bundles = try await KeyServiceClient.shared.getPreKeyBundles(userId: recipientUserId, consumeOneTimePrekey: true)
            guard !bundles.isEmpty else {
                await recordSkip("no_bundles", peer: recipientUserId)
                enqueueRetry(messageId, recipientUserId, senderUserId, owed: [])
                return .replan
            }

            let ourIdentityKey = KeychainManager.shared.loadDeviceIdentityKey()
            let targets = DeviceDeliveryPlan.targets(
                recipientDevices: bundles,
                ownDevices: [],
                ourDeviceId: senderDeviceId,
                recipientIsSelf: false,
                // The primary send already reached the device the recipient's pinned key names —
                // it is the session `SessionAddressing` resolves to. Planning a copy for it would
                // put two ciphertexts of one message through one ratchet.
                primarySendCovered: SessionAddressing.contactId(forPeer: recipientUserId)
            )
            // Not a plan of our own — the plan is the core's, above, and this only drops the
            // entries a retry must not repeat. A device that already has its copy would get a
            // second ciphertext of one message through one ratchet and render it twice, so a
            // retry narrows to what a previous attempt said it owed and never widens.
            let planned = onlyDevices.map { owed in
                targets.filter { owed.contains($0.deviceId) }
            } ?? targets
            guard !planned.isEmpty else {
                // Two different silences. On a first attempt this is the ordinary single-device
                // recipient whose only device the primary send already covered — debug, and not a
                // skip. On a retry it means the devices a previous attempt owed are no longer in
                // the plan: revoked, or a partial bundle list. The entry is left to exhaust rather
                // than dropped, because those two causes are not separable here and giving up on
                // the second would lose a copy that a later fetch could still place.
                Log.debug(
                    "MultiDevice fan-out: no targets for \(recipientUserId.prefix(8))… — " +
                    "\(bundles.count) device(s) known" +
                    (onlyDevices.map { ", none of the \($0.count) owed still planned" }
                        ?? ", primary send covered the rest"),
                    category: "MultiDevice"
                )
                return .complete
            }

            // One Privacy Pass spend for the whole logical message, across every device and every
            // chunk. The unit of spend is a message to a **person**, and `token_spend_id` is bound
            // to `recipient_user_id`, so N copies to one recipient are covered once. Sealing the
            // fan-out is what makes this matter: an unsealed copy paid nothing, and paying per
            // envelope instead would multiply a three-photo album by the recipient's device count
            // and empty a young account's hourly allowance on one tap.
            let spendUnit = await TokenSpendUnit.forEnvelopeCount(planned.count * chunks.count)

            var owed: [String] = []
            for target in planned {
                // The tag replaces `-fd-<deviceId.prefix(8)>`, which named the target device in
                // plain hex to the relay on every copy it routed — the leak closed for the
                // own-replica path on 2026-08-17 and left standing here, on the neighbouring path
                // carrying the same fact. Nothing ever read that suffix back, so nothing depended
                // on it either.
                let tag = Self.senderSyncTag(
                    baseMessageId: messageId,
                    targetDeviceId: target.deviceId,
                    targetIdentityPublic: target.identityPublic,
                    ourIdentityPrivateKey: ourIdentityKey
                )
                var landed = true
                for (index, payload) in chunks.enumerated() {
                    let ok = await sendToDevice(
                        plaintext: payload,
                        messageId: DeviceDeliveryPlan.wireId(
                            baseMessageId: messageId, tag: tag,
                            audience: target.audience,
                            chunkIndex: index, chunkCount: chunks.count
                        ),
                        networkRecipientUserId: recipientUserId,
                        contactId: target.deviceId,
                        bundle: target.bundle,
                        senderUserId: senderUserId,
                        recipientDeviceId: target.deviceId,
                        timestamp: timestamp,
                        contentType: .e2EeSignal,
                        audience: .peerDevice(identityKey: target.identityPublic),
                        spendUnit: spendUnit
                    )
                    // One failed chunk owes the whole message to that device, not the chunk: a
                    // partial set never reassembles, so re-sending only the missing frame would
                    // leave the copy exactly as undeliverable as it is now. The chunk loop is not
                    // cut short for the same reason a device failure does not stop the others —
                    // one device's broken session says nothing about the next chunk's.
                    if !ok { landed = false }
                }
                if !landed { owed.append(target.deviceId) }
            }
            if owed.isEmpty {
                // Everything the plan named is delivered. Clears an entry left by an earlier
                // attempt — without this the queue would keep re-sending a message that has
                // already arrived, which is worse than the gap it was built to close.
                FanoutRetryQueue.shared.remove(key: "\(messageId)|\(recipientUserId)")
                return .complete
            } else {
                enqueueRetry(messageId, recipientUserId, senderUserId, owed: owed)
                return .owed(owed)
            }
        } catch {
            await recordSkip("bundle_fetch_failed", peer: recipientUserId, error: error)
            // The 2026-08-28 shape: a single fetch, timed out, no retry, and the copy never
            // existed. Empty `owed` because the call that would have named the devices is the one
            // that failed — the drain re-plans from scratch, which is correct since nothing went.
            enqueueRetry(messageId, recipientUserId, senderUserId, owed: [])
            return .replan
        }
    }

    /// Send the copies earlier attempts owed, for entries whose backoff has elapsed.
    ///
    /// Called when the network comes back, beside the primary send's own queue drain — the two
    /// answer different questions ("did it reach the recipient" versus "did it reach all of their
    /// devices") and a message can be complete by the first and owed by the second.
    ///
    /// The payload is rebuilt from the persisted row rather than stored, for the reason given on
    /// `FanoutRetryEntry`. That inherits `recoverWirePlaintext`'s limit: a media message cannot be
    /// rebuilt, so it is given up on rather than retried forever, and counted where the number can
    /// be read. Fixing that means retaining album protos, which is a change to what this app keeps
    /// on disk and is not §C's to make.
    ///
    /// Serial, not concurrent: each entry consumes a one-time pre-key per device from a fetch that
    /// is destructive by design, and a burst of parallel drains after a reconnect is how an account
    /// runs out of them. See `decisions/prekey-bundle-fetch-is-destructive.md`.
    func drainRetryQueue(currentUserId: String) async {
        guard !isDraining else { return }
        let due = FanoutRetryQueue.shared.due()
        guard !due.isEmpty else { return }

        isDraining = true
        defer { isDraining = false }

        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else {
            Log.info("Fan-out retry drain skipped — no device id", category: "MultiDevice")
            return
        }

        Log.info("Fan-out retry drain: \(due.count) entr\(due.count == 1 ? "y" : "ies") due", category: "MultiDevice")

        for entry in due {
            // The attempt is spent before it is made, not after. A drain that crashes or is
            // backgrounded mid-send would otherwise leave the count untouched and retry the same
            // entry on every reconnect for a day.
            guard FanoutRetryQueue.shared.recordAttempt(key: entry.key) != nil else {
                PerformanceMetrics.shared.record(.fanoutRetryGaveUp, label: "exhausted")
                Log.info(
                    "Fan-out retry gave up on \(entry.baseMessageId.prefix(8))… after \(FanoutRetryQueue.shared.maxAttempts) attempts",
                    category: "MultiDevice"
                )
                continue
            }

            // Both answers from one fetch. Asking twice — once for the plaintext, once to tell a
            // missing row from an unrebuildable one — would let the row be deleted in between and
            // label the outcome by a state that no longer holds.
            let context = PersistenceController.shared.container.newBackgroundContext()
            let recovered: (plaintext: Data?, rowExists: Bool) = await context.perform {
                let fr = Message.fetchRequest()
                fr.predicate = NSPredicate(format: "id == %@", entry.baseMessageId)
                fr.fetchLimit = 1
                guard let row = try? context.fetch(fr).first else { return (nil, false) }
                return (MessageRetryManager.recoverWirePlaintext(for: row), true)
            }

            guard let plaintext = recovered.plaintext else {
                // Two different endings sharing one shape, so they are labelled apart: a row that
                // is gone is benign, a row that cannot be rebuilt is a copy permanently lost.
                PerformanceMetrics.shared.record(
                    .fanoutRetryGaveUp,
                    label: recovered.rowExists ? "not_reconstructable" : "no_row"
                )
                FanoutRetryQueue.shared.remove(key: entry.key)
                continue
            }

            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: plaintext,
                messageId: UUID(uuidString: entry.baseMessageId) ?? UUID()
            )
            guard !plan.payloads.isEmpty else {
                PerformanceMetrics.shared.record(.fanoutRetryGaveUp, label: "not_reconstructable")
                FanoutRetryQueue.shared.remove(key: entry.key)
                continue
            }

            let outcome = await fanOutToRecipientDevices(
                chunks: plan.payloads,
                messageId: entry.baseMessageId,
                recipientUserId: entry.recipientUserId,
                senderUserId: entry.senderUserId.isEmpty ? currentUserId : entry.senderUserId,
                senderDeviceId: myDeviceId,
                timestamp: UInt64(Date().timeIntervalSince1970),
                // Empty means the fetch never named anyone, so the retry re-plans; a named set
                // narrows to exactly the devices the previous attempt lost.
                onlyDevices: entry.owedDeviceIds.isEmpty ? nil : entry.owedDeviceIds
            )

            // The entry is updated from what this attempt actually lost, not left as it was. A
            // re-plan that reaches one device and loses another has to come out of the pass naming
            // only the one it lost: leaving it a re-plan would send the first device a second
            // ciphertext of the same message on the next drain, which is the defect this whole
            // line of work exists to remove, re-entered from the repair side.
            switch outcome {
            case .complete:
                FanoutRetryQueue.shared.remove(key: entry.key)
            case .owed(let still):
                FanoutRetryQueue.shared.replaceOwed(key: entry.key, owed: still)
            case .replan:
                // Still nothing that can name the devices. The entry keeps its spent attempt and
                // its shape; the next pass tries the fetch again.
                break
            case .notRetryable:
                PerformanceMetrics.shared.record(.fanoutRetryGaveUp, label: "not_retryable")
                FanoutRetryQueue.shared.remove(key: entry.key)
            }
        }
    }

    /// Record that a message still owes copies, unless this *is* the retry.
    ///
    /// A drain pass that fails must not enqueue a fresh entry beside the one it is working on —
    /// that would reset the attempt count and make the queue immortal. The drain owns the
    /// lifecycle of an entry it picked up; this only creates one for a first-time failure.
    private func enqueueRetry(
        _ messageId: String,
        _ recipientUserId: String,
        _ senderUserId: String,
        owed: [String]
    ) {
        guard !isDraining else { return }
        FanoutRetryQueue.shared.enqueue(
            baseMessageId: messageId,
            recipientUserId: recipientUserId,
            senderUserId: senderUserId,
            owed: owed
        )
    }

    /// SenderSync: send a copy of an outgoing message to all of the sender's OWN
    /// other devices, encrypted with per-device sessions, content type = senderSync.
    ///
    /// `plaintext` MUST be the same **wire** bytes used for the primary send
    /// (`MessageContent` / pre-KNST payload), NOT display JSON or CTM1. This coordinator
    /// applies the same KNST chunking as `ChunkedMessageSender` so large albums and voice
    /// descriptors reassemble on the peer device. Receiving side stores CTM1 via the
    /// normal reassembler (`storagePayload`). See local-message-payload-binary.md C1c.
    ///
    /// Receiving devices show this as an outgoing bubble (sent by the local user)
    /// in the conversation with `originalRecipientUserId`.
    ///
    /// IMPORTANT: Multi-device internal traffic (SenderSync, fan-out to own devices,
    /// broadcast resets) deliberately does NOT use Stealth/Sealed Sender.
    /// Server already knows this is the same user account. See stealth scope decisions.
    ///
    /// Errors are logged and swallowed — SenderSync is best-effort.
    func sendSenderSync(
        plaintext: Data,
        messageId: String,
        originalRecipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        timestamp: UInt64
    ) async {
        guard !senderDeviceId.isEmpty else { return }
        guard !plaintext.isEmpty else {
            Log.info("SenderSync: empty wire plaintext — skip", category: "MultiDevice")
            return
        }
        do {
            let otherDevices = try await fetchOwnOtherDevices(
                myUserId: senderUserId,
                myDeviceId: senderDeviceId
            )
            guard !otherDevices.isEmpty else { return }

            // Same framing as the primary send path so the peer reassembler can rebuild
            // MessageContent → CTM1. UUID from base messageId when well-formed.
            let planId = UUID(uuidString: messageId) ?? UUID()

            // The routing header goes on before chunking, so a multi-chunk sync carries it once
            // and the receiver strips it once, after reassembly. Without it the receiving device
            // cannot tell which conversation this copy belongs to: sender and recipient on the
            // wire are both us, and `conversation_id` is blanked by the server by design.
            //
            // A partner id that is not a UUID yields no header rather than a malformed one; that
            // send lands on the same unroutable path as a sender running an older build, which is
            // where all of them landed before this existed.
            let framedPlaintext: Data
            if let header = SenderSyncRouting(partnerUserId: originalRecipientUserId).encoded() {
                framedPlaintext = header + plaintext
            } else {
                Log.error(
                    "SenderSync: partner id '\(originalRecipientUserId.prefix(8))…' is not a UUID — sending without routing header, the copy will not be placeable",
                    category: "MultiDevice"
                )
                framedPlaintext = plaintext
            }

            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: framedPlaintext,
                messageId: planId,
                // Byte 5 of the KNST header exists to carry the content type inside the ciphertext.
                // SENDER_SYNC was leaving it at the default 1, so the frame described itself as an
                // ordinary chat message while the envelope said 23.
                contentType: WireMessageKind.senderSync.canonicalContentType
            )
            guard !plan.payloads.isEmpty else {
                Log.info("SenderSync: chunk plan empty (payload too large?) — skip", category: "MultiDevice")
                return
            }

            // Our identity private key: the other half of the X25519 pair whose public half is in
            // every device's bundle. Absent only before registration completes, and then there are
            // no own devices to sync to either.
            let ourIdentityKey = KeychainManager.shared.loadDeviceIdentityKey()

            // Targets from the same place the recipient fan-out gets them, so "which devices, and
            // is this one of them" is answered once. `otherDevices` has already dropped this
            // device; the plan drops it again, which is deliberate — the filter belongs to the
            // decision, not to whichever caller remembered it.
            let targets = DeviceDeliveryPlan.targets(
                recipientDevices: [],
                ownDevices: otherDevices,
                ourDeviceId: senderDeviceId,
                recipientIsSelf: true
            )

            for target in targets {
                // The tag names the device this copy is for, to that device only. It used to be
                // `deviceId.prefix(8)` — the id in plain hex, which the relay reads on every copy
                // it routes. See SenderSyncDeviceTag.
                let deviceTag = Self.senderSyncTag(
                    baseMessageId: messageId,
                    targetDeviceId: target.deviceId,
                    targetIdentityPublic: target.identityPublic,
                    ourIdentityPrivateKey: ourIdentityKey
                )
                for (index, payload) in plan.payloads.enumerated() {
                    // Discarded on purpose: SENDER_SYNC is a copy to one of *our* devices, and
                    // §C's queue retries copies owed to the **recipient**. A sibling that misses
                    // one heals on its next exchange, and re-sending here would need a second
                    // queue keyed by our own account. Counted (`sync_send_failed`), not retried —
                    // the number says whether that second queue is worth building.
                    _ = await sendToDevice(
                        plaintext: payload,
                        messageId: DeviceDeliveryPlan.wireId(
                            baseMessageId: messageId, tag: deviceTag,
                            audience: target.audience,
                            chunkIndex: index, chunkCount: plan.payloads.count
                        ),
                        networkRecipientUserId: senderUserId,
                        contactId: target.deviceId,
                        bundle: target.bundle,
                        senderUserId: senderUserId,
                        recipientDeviceId: target.deviceId,
                        timestamp: timestamp,
                        contentType: .senderSync,
                        audience: .ownDevice
                    )
                }
            }
        } catch {
            Log.info(
                "SenderSync: own-device fetch failed for \(senderUserId.prefix(8))…: \(error)",
                category: "MultiDevice"
            )
        }
    }

    // MARK: - Private helpers

    /// One device did not get its copy — count it and say why.
    ///
    /// Every exit from the fan-out used to be a `Log.info` and a `return`, which is why the
    /// release gate for §C could not be evaluated: nothing separated "this account has one device"
    /// from "the second device was never reached". See `MetricEvent.fanoutDeviceSkipped` for the
    /// closed set of reasons and for why this counts occurrences rather than devices.
    ///
    /// The `believed=` figure comes from `PeerDevice` — the durable account → devices directory
    /// filled at the same seam that fetches bundles — and is deliberately not folded into the
    /// counter. It is what we were last told, possibly hours ago; on the fetch-side reasons it is
    /// the only device count available precisely because the call that would refresh it is the one
    /// that just failed. A belief in the log, a fact in the metric.
    private func recordSkip(
        _ reason: String,
        peer: String,
        error: Error? = nil,
        device: String? = nil
    ) async {
        PerformanceMetrics.shared.record(.fanoutDeviceSkipped, label: reason)

        let believed: Int
        if peer.isEmpty {
            believed = 0
        } else {
            let context = PersistenceController.shared.container.newBackgroundContext()
            believed = await context.perform {
                SessionAddressing.deviceIds(ofPeer: peer, in: context).count
            }
        }

        let target = device.map { " device=\($0.prefix(8))…" } ?? ""
        let why = error.map { ": \($0)" } ?? ""
        Log.info(
            "MultiDevice fan-out skipped for \(peer.prefix(8))… — reason=\(reason)" +
            "\(target) believed=\(believed)\(why)",
            category: "MultiDevice"
        )
    }


    private func fetchOwnOtherDevices(myUserId: String, myDeviceId: String) async throws -> [DeviceBundleData] {
        if let cache = ownDeviceCache,
           Date().timeIntervalSince(cache.fetchedAt) < cacheTTL {
            return cache.bundles.filter { $0.deviceId != myDeviceId }
        }
        // Enumerating OUR OWN devices — never burn our own one-time pre-keys just to
        // list them. (The server also refuses to consume on a self-fetch.)
        let all = try await KeyServiceClient.shared.getPreKeyBundles(userId: myUserId, consumeOneTimePrekey: false)
        ownDeviceCache = DeviceCache(bundles: all, fetchedAt: Date())
        // Sync our own SPK upload timestamp from the server-reported value.
        // This corrects stale local UserDefaults (e.g. set to Date.now during
        // account recovery while the server still holds an older key).
        if let own = all.first(where: { $0.deviceId == myDeviceId }),
           own.bundle.spkUploadedAt > 0 {
            PreKeyRotationService.shared.syncSpkUploadTimestamp(
                serverUploadedAt: TimeInterval(own.bundle.spkUploadedAt)
            )
        }
        return all.filter { $0.deviceId != myDeviceId }
    }

    /// Whose device this copy is going to — which is the only thing that decides whether it may
    /// travel unsealed.
    ///
    /// The caller answers because the caller is the only one that knows. `sendToDevice` used to
    /// hardcode `.identified(.ownDevices)` for both of its callers, and for one of them the claim
    /// was false: a copy to a **peer's** device has `senderUserId` = us and
    /// `networkRecipientUserId` = them, so the relay got exactly the pair sealed sender exists to
    /// hide — once per extra device of theirs, per message.
    enum DeviceCopyAudience {
        /// A peer's device. Sealed to the identity key from the bundle we just fetched for it —
        /// the value is in the caller's hand, which is the point: `recipientIdentityKey` would go
        /// looking for it in a store that holds one key per account and does not know this device.
        case peerDevice(identityKey: Data)

        /// One of our own devices. The pair is (me, me), which the relay knows from the
        /// authenticated channel before it opens the envelope, and `conversation_id` is empty — so
        /// a seal would hide nothing. See `SealingExemption.ownDevices`.
        case ownDevice
    }

    /// Core per-device send: ensures session exists, encrypts, sends. Swallows errors.
    private func sendToDevice(
        plaintext: Data,
        messageId: String,
        networkRecipientUserId: String,
        contactId: String,
        bundle: PublicKeyBundleData,
        senderUserId: String,
        recipientDeviceId: String,
        timestamp: UInt64,
        contentType: Shared_Proto_Core_V1_ContentType,
        audience: DeviceCopyAudience,
        spendUnit: TokenSpendUnit? = nil
    ) async -> Bool {
        do {
            // Ensure a session exists for this contactId; never clobber an existing one.
            if !CryptoManager.shared.hasSession(for: contactId) {
                do {
                    _ = try SessionInitializationService.shared.initializeSession(
                        userId: contactId,
                        bundle: bundle,
                        deleteExisting: false
                    )
                } catch SessionError.peerSPKStale {
                    // Own replica has been offline too long to rotate its SPK — degrade rather
                    // than drop the sync. Flags the session at-risk (see stale-peer-reachability).
                    _ = try SessionInitializationService.shared.initializeSession(
                        userId: contactId,
                        bundle: bundle,
                        deleteExisting: false,
                        allowStale: true
                    )
                }
            }

            let encPayload = try OutboundSessionService.shared.encryptOutgoing(
                plaintext: plaintext,
                messageId: messageId,
                recipientId: contactId
            )

            // §B: the copy answers the sealing question by audience, not by being multi-device
            // traffic. A peer's device is sealed to its own identity key — the same key its ratchet
            // already runs on, so this is not a stronger claim about that key than the session
            // already makes, and the receiving device opens it with its own private key.
            let sealing: SendSealing
            switch audience {
            case .ownDevice:
                sealing = .identified(.ownDevices)
            case .peerDevice(let identityKey):
                if StealthPolicy.shared.shouldUseSealedSender() {
                    sealing = .sealed(try await StealthSenderService.buildSealedInner(
                        recipientUserId: networkRecipientUserId,
                        recipientIdentityKey: identityKey,
                        encryptedPayload: encPayload,
                        // Generic on purpose. The outer type used to be `.e2EeSignal`, which let the
                        // server tell a body copy from a control copy; under a seal the baseline is
                        // the field's absence, and the real type rides in KNST byte 5 inside the
                        // ciphertext like every other sealed body.
                        contentType: .generic,
                        spendUnit: spendUnit
                    ))
                } else {
                    // DEBUG only: `StealthPolicy.isEnabled` is a compile-time `true` in Release, and
                    // the chokepoint refuses this branch whenever stealth is on.
                    sealing = .identified(.stealthDisabled)
                }
            }

            // conversation_id stays empty on purpose. `direct:<me>:<partner>` names the person on
            // the other side, in the clear, once per extra device per message — for a multi-device
            // account it handed the server exactly the pairing sealed sender exists to hide.
            //
            // Nothing wanted it. `Envelope.conversation_id` has no reader anywhere on the server —
            // the only consumers of a field by that name are APNs payloads fed from group and
            // request ids, the message push path passes None, and it is in no migration — and the
            // server blanks it on delivery besides. The client stopped reading it from a received
            // envelope when SENDER_SYNC began routing from inside the ciphertext.
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: messageId,
                recipientId: networkRecipientUserId,
                senderId: senderUserId,
                conversationId: "",
                encryptedPayload: encPayload,
                timestamp: timestamp,
                // Written only on the unsealed branch by `buildEnvelope`, because the outer field is
                // visible to the relay. On the sealed branch the device is derived from the key the
                // seal was built against, so "who can open this" and "where does it go" stay one
                // value rather than two that must be kept in agreement.
                recipientDeviceId: recipientDeviceId,
                contentType: contentType,
                sealing: sealing
            )

            CryptoManager.shared.saveSessionToKeychain(for: contactId)
            Log.info(
                "MultiDevice[\(contentType == .senderSync ? "sync" : "fanout")]: sent to \(contactId.prefix(20))…",
                category: "MultiDevice"
            )
            return true
        } catch {
            // A device that did not get its copy, and the one reason here where we know exactly
            // which device it was — the loop is holding it. SENDER_SYNC is labelled apart because
            // it is a device of *ours*, and "the peer never saw it" and "my iPad never saw it" are
            // different failures with the same shape.
            await recordSkip(
                contentType == .senderSync ? "sync_send_failed" : "send_failed",
                peer: networkRecipientUserId,
                error: error,
                device: contactId
            )
            return false
        }
    }

    // MARK: - Session Reset Broadcast (Изъян 8)

    /// Изъян 8: tell the user's other devices that the DR session with `contactId` was reset, so
    /// each can heal independently.
    ///
    /// **Not implemented — the send was removed on 2026-08-03 because it had no reader.**
    ///
    /// It used to encrypt `"__session_reset_notify__<contactId>__"` to every linked device with
    /// `content_type = SENDER_SYNC`. A repository-wide search finds zero consumers of that string:
    /// no device ever healed because of it. What it did do was arrive in `saveSenderSyncMessage`,
    /// fail every control-format check, fall through to the plain-text branch and get **saved as a
    /// visible message bubble containing that literal string** — so the feature's only observable
    /// effect was littering the transcript of multi-device accounts.
    ///
    /// Deleting the send loses nothing (no behaviour depended on it) and stops the litter. The
    /// metric below counts how often the notification *would* have gone out, which is the number
    /// worth having before deciding whether to build the real thing: a working version needs a
    /// routable content type plus a heal-trigger policy (when to heal, how not to loop two devices
    /// into healing each other), and that is a design decision, not a wiring fix. See TODO 32.
    func broadcastSessionReset(contactId: String) async {
        PerformanceMetrics.shared.record(
            .linkedDeviceResetNotifyUnimplemented,
            label: String(contactId.prefix(8))
        )
        Log.info(
            "Session reset with \(contactId.prefix(8))… — linked devices NOT notified (Изъян 8 unimplemented; they heal on their own next failed decrypt)",
            category: "MultiDevice"
        )
    }
}

