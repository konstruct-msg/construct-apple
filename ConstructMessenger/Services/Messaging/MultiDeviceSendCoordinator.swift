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
//  Primary (legacy, single-device) sessions use plain `userId` as the contactId in the
//  Rust OrchestratorCore. Per-device sessions use `userId:deviceId` (colon-separated).
//  UserIds are hex/UUID strings that cannot contain a colon, so there is no collision risk.
//
//  Threading
//  ─────────
//  @MainActor — CryptoManager and SessionInitializationService both require main-actor
//  access. Fire-and-forget via a detached Task where callers are already on MainActor.
//

import Foundation
import CryptoKit

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
        timestamp: UInt64
    ) async {
        guard !senderDeviceId.isEmpty, !chunks.isEmpty else { return }
        do {
            // Per-device fan-out to a recipient: a device we have no session with yet needs
            // X3DH, so this fetch legitimately consumes a one-time pre-key.
            let bundles = try await KeyServiceClient.shared.getPreKeyBundles(userId: recipientUserId, consumeOneTimePrekey: true)
            guard !bundles.isEmpty else { return }

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
            guard !targets.isEmpty else { return }

            for target in targets {
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
                for (index, payload) in chunks.enumerated() {
                    await sendToDevice(
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
                        senderDeviceId: senderDeviceId,
                        recipientDeviceId: target.deviceId,
                        timestamp: timestamp,
                        contentType: .e2EeSignal
                    )
                }
            }
        } catch {
            Log.info(
                "MultiDevice fan-out: bundle fetch failed for \(recipientUserId.prefix(8))…: \(error)",
                category: "MultiDevice"
            )
        }
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
                    await sendToDevice(
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
                        senderDeviceId: senderDeviceId,
                        recipientDeviceId: target.deviceId,
                        timestamp: timestamp,
                        contentType: .senderSync
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

    /// Core per-device send: ensures session exists, encrypts, sends. Swallows errors.
    private func sendToDevice(
        plaintext: Data,
        messageId: String,
        networkRecipientUserId: String,
        contactId: String,
        bundle: PublicKeyBundleData,
        senderUserId: String,
        senderDeviceId: String,
        recipientDeviceId: String,
        timestamp: UInt64,
        contentType: Shared_Proto_Core_V1_ContentType
    ) async {
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

            // Explicitly never use stealth for multi-device traffic (see comment above).
            let encPayload = try OutboundSessionService.shared.encryptOutgoing(
                plaintext: plaintext,
                messageId: messageId,
                recipientId: contactId
            )

            // conversation_id stays empty on purpose. Multi-device traffic is deliberately not
            // sealed — the reasoning being that the server already knows this is one account,
            // which is true of the sender and the recipient, both of them us. It is not true of
            // `direct:<me>:<partner>`: that names the person on the other side, in the clear, on
            // an unsealed envelope, once per own device per message sent. For a multi-device
            // account it handed the server exactly the pairing that sealed sender exists to hide.
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
                senderDeviceId: senderDeviceId,
                recipientDeviceId: recipientDeviceId,
                contentType: contentType
            )

            CryptoManager.shared.saveSessionToKeychain(for: contactId)
            Log.info(
                "MultiDevice[\(contentType == .senderSync ? "sync" : "fanout")]: sent to \(contactId.prefix(20))…",
                category: "MultiDevice"
            )
        } catch {
            Log.info(
                "MultiDevice: failed to send to \(contactId.prefix(20))…: \(error)",
                category: "MultiDevice"
            )
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

