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
            let bundles = try await KeyServiceClient.shared.getPreKeyBundles(userId: recipientUserId)
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
        do {
            let otherDevices = try await fetchOwnOtherDevices(
                myUserId: senderUserId,
                myDeviceId: senderDeviceId
            )
            guard !otherDevices.isEmpty else { return }

            for device in otherDevices {
                let contactId = Self.sessionKey(userId: senderUserId, deviceId: device.deviceId)
                await sendToDevice(
                    plaintext: plaintext,
                    messageId: "\(messageId)-ss-\(device.deviceId.prefix(8))",
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
        let all = try await KeyServiceClient.shared.getPreKeyBundles(userId: myUserId)
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

    /// Изъян 8: Notify all own linked devices that the DR session with `contactId` was reset.
    ///
    /// Each device receiving this notification should independently trigger a heal with the contact.
    /// Failures are non-fatal — best-effort delivery.
    func broadcastSessionReset(contactId: String) async {
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else { return }
        let ownDevices: [DeviceBundleData]
        do {
            ownDevices = try await fetchOwnOtherDevices(myUserId: myId, myDeviceId: myDeviceId)
        } catch {
            Log.info("broadcastSessionReset: failed to fetch own devices: \(error.localizedDescription)", category: "MultiDevice")
            return
        }
        guard !ownDevices.isEmpty else {
            Log.debug("No linked devices to notify of session reset with \(contactId.prefix(8))…", category: "MultiDevice")
            return
        }
        let resetPayload = "__session_reset_notify__\(contactId)__"
        for device in ownDevices {
            let msgId = UUID().uuidString.lowercased()
            let syncContactId = "\(myId):\(device.deviceId)"
            do {
                guard CryptoManager.shared.hasSession(for: syncContactId) else { continue }
                // Explicitly no stealth for device-to-device session reset notifications
                // (internal to the user, see multi-device exclusion in stealth scope).
                let payload = try OutboundSessionService.shared.encryptSessionControl(
                    plaintext: resetPayload,
                    messageId: msgId,
                    recipientId: syncContactId
                )
                _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: msgId,
                    recipientId: myId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: myId),
                    encryptedPayload: payload,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    senderDeviceId: myDeviceId,
                    recipientDeviceId: device.deviceId,
                    contentType: .senderSync
                )
                Log.debug("Session-reset notification sent to own device \(device.deviceId.prefix(8))…", category: "MultiDevice")
            } catch {
                Log.info("Session-reset notify failed for device \(device.deviceId.prefix(8))…: \(error.localizedDescription)", category: "MultiDevice")
            }
        }
    }
}

