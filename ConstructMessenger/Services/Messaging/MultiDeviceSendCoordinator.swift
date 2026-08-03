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

    /// Derive the session contactId for a specific device (non-primary sessions).
    static func sessionKey(userId: String, deviceId: String) -> String {
        "\(userId):\(deviceId)"
    }

    /// Fan-out: send `plaintext` to ALL of the recipient's devices.
    ///
    /// Intended for use after the primary send (which already covers the recipient's
    /// default device via the plain `userId` session). Each device gets its own
    /// E2EE session keyed by `recipientUserId:deviceId`.
    ///
    /// Errors per-device are logged and skipped; the function never throws.
    func fanOutToRecipientDevices(
        plaintext: Data,
        messageId: String,
        recipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        conversationId: String,
        timestamp: UInt64
    ) async {
        guard !senderDeviceId.isEmpty else { return }
        do {
            // Per-device fan-out to a recipient: a device we have no session with yet needs
            // X3DH, so this fetch legitimately consumes a one-time pre-key.
            let bundles = try await KeyServiceClient.shared.getPreKeyBundles(userId: recipientUserId, consumeOneTimePrekey: true)
            guard !bundles.isEmpty else { return }

            for device in bundles {
                let contactId = Self.sessionKey(userId: recipientUserId, deviceId: device.deviceId)
                await sendToDevice(
                    plaintext: plaintext,
                    messageId: "\(messageId)-fd-\(device.deviceId.prefix(8))",
                    networkRecipientUserId: recipientUserId,
                    contactId: contactId,
                    bundle: device.bundle,
                    senderUserId: senderUserId,
                    senderDeviceId: senderDeviceId,
                    recipientDeviceId: device.deviceId,
                    conversationId: conversationId,
                    timestamp: timestamp,
                    contentType: .e2EeSignal
                )
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
        conversationId: String,
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
            let plan = ChunkedMessageSender.shared.buildPlan(plaintext: plaintext, messageId: planId)
            guard !plan.payloads.isEmpty else {
                Log.info("SenderSync: chunk plan empty (payload too large?) — skip", category: "MultiDevice")
                return
            }

            for device in otherDevices {
                let contactId = Self.sessionKey(userId: senderUserId, deviceId: device.deviceId)
                let deviceTag = String(device.deviceId.prefix(8))
                for (index, payload) in plan.payloads.enumerated() {
                    let chunkWireId: String = plan.payloads.count == 1
                        ? "\(messageId)-ss-\(deviceTag)"
                        : "\(messageId)-ss-\(deviceTag)-c\(index)"
                    await sendToDevice(
                        plaintext: payload,
                        messageId: chunkWireId,
                        networkRecipientUserId: senderUserId,
                        contactId: contactId,
                        bundle: device.bundle,
                        senderUserId: senderUserId,
                        senderDeviceId: senderDeviceId,
                        recipientDeviceId: device.deviceId,
                        conversationId: conversationId,
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
        conversationId: String,
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

            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: messageId,
                recipientId: networkRecipientUserId,
                senderId: senderUserId,
                conversationId: conversationId,
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

