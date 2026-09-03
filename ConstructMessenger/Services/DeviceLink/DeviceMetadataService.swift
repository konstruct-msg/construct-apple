//
//  DeviceMetadataService.swift
//  Construct Messenger
//
//  A device's name and platform, readable by its own account and by nobody else.
//

import Foundation
import SwiftProtobuf

/// What a device says about itself to the other devices of its account.
///
/// ## Why it is sealed at all
///
/// Migration `013_privacy_simplify_devices.sql` dropped `device_name` and `platform` from the
/// server's `devices` table, naming them in its own header as device fingerprinting and an OS
/// leak. That decision stands. What it cost is the device list: with nothing to show but an id,
/// two links of one Mac are two identical rows, and the revoked one is indistinguishable from the
/// live one. 2026-09-03: a Desktop that had been revoked kept running for a day, and its
/// handshakes archived the sibling's session on every peer it talked to — 41 times out of 42.
///
/// So the fields come back, but as a blob the server stores and cannot read
/// (`DeviceInfo.sealed_metadata`, `SetDeviceMetadata`).
///
/// ## Why per device, not under one account key
///
/// The account has no shared key. Every device holds its own X25519 identity pair, and linking
/// establishes nothing between them — it passes a JWT and pre-keys. Rather than invent one, the
/// metadata is sealed once per sibling and the copies stored together.
///
/// That costs a copy per device, units of them. What it buys is revocation: a removed device
/// simply stops being sealed to on the next re-seal. A shared key would keep it readable until
/// someone rotated a key that today has no rotation.
///
/// ## Why the copies carry no labels
///
/// A reader finds its own by trying each — one X25519 and one AEAD open per copy. The blob could
/// have said which copy belongs to whom and saved that work, and it deliberately does not: the
/// server promised not to parse this, and a field that makes parsing convenient is an invitation
/// to start.
enum DeviceMetadataService {

    /// The largest blob the server accepts (`SetDeviceMetadataRequest`, 4 KiB). Larger is
    /// `INVALID_ARGUMENT` and never a silent truncation, so the limit is checked here too — a
    /// rejected upload leaves the account with the *previous* blob, which is worse than an
    /// obviously unnamed device because it is silently out of date.
    ///
    /// It grows with the device count, which is why it is not tight: a copy is
    /// `ephemeral(32) + nonce(12) + payload + tag(16)`, so a two-field description runs around 90
    /// bytes and 4 KiB holds a few dozen devices. An account that reached the cap would have long
    /// since had a different problem.
    static let maxBlobBytes = 4096

    // MARK: - Building

    /// This device's own metadata.
    ///
    /// The name defaults to the platform, not to the system device name. `DeviceInfo.deviceName`
    /// is "iPhone 15 Pro" — a model string, which is the fingerprint 013 removed. That the server
    /// can no longer read it does not make it a good default: it still reaches every device of the
    /// account, and a person who wants their Mac called "work laptop" should say so rather than
    /// have the model volunteered for them.
    nonisolated static func selfDescription() -> Shared_Proto_Services_V1_DeviceMetadata {
        var meta = Shared_Proto_Services_V1_DeviceMetadata()
        #if os(iOS)
        meta.platform = .ios
        meta.deviceName = NSLocalizedString("device_default_name_ios", comment: "")
        #else
        meta.platform = .desktop
        meta.deviceName = NSLocalizedString("device_default_name_desktop", comment: "")
        #endif
        return meta
    }

    /// Seal one description to every device of the account, ours included.
    ///
    /// Ours included on purpose: this device reads the blob back through the same path as any
    /// other, so a copy it cannot open would make its own row the one unnamed entry in the list.
    ///
    /// `nil` when there is nothing to seal to — an empty device set is a cold cache or a failed
    /// fetch, and publishing a blob with no copies would clear the account's name for this device
    /// rather than leave the previous one standing.
    nonisolated static func seal(
        _ metadata: Shared_Proto_Services_V1_DeviceMetadata,
        toIdentityKeys keys: [Data]
    ) -> Data? {
        guard !keys.isEmpty, let plaintext = try? metadata.serializedData() else { return nil }

        var sealed = Shared_Proto_Services_V1_SealedDeviceMetadata()
        for key in keys {
            guard let copy = try? sealToDeviceKey(
                plaintext: [UInt8](plaintext),
                deviceIdentityKey: [UInt8](key)
            ) else {
                // One unusable key must not cost the other devices their copy: a bundle can carry
                // a key of the wrong length, and dropping the whole blob for it would leave every
                // sibling unnamed because one of them was malformed.
                Log.error("DeviceMetadata: could not seal to a device key — skipping that copy", category: "DeviceLink")
                continue
            }
            sealed.copies.append(Data(copy))
        }
        guard !sealed.copies.isEmpty, let blob = try? sealed.serializedData() else { return nil }
        guard blob.count <= maxBlobBytes else {
            Log.error(
                "DeviceMetadata: blob is \(blob.count) bytes for \(sealed.copies.count) device(s) — over the \(maxBlobBytes) limit, not publishing",
                category: "DeviceLink"
            )
            return nil
        }
        return blob
    }

    // MARK: - Reading

    /// Open the copy meant for us, or `nil` when none of them is.
    ///
    /// `nil` is an ordinary answer, not a failure: a device linked after the last re-seal has no
    /// copy in a sibling's blob and stays unnamed until they re-seal. The list falls back to the
    /// device id, which identifies it regardless.
    nonisolated static func open(
        _ blob: Data,
        withIdentityPrivateKey ourKey: Data
    ) -> Shared_Proto_Services_V1_DeviceMetadata? {
        guard !blob.isEmpty, !ourKey.isEmpty,
              let sealed = try? Shared_Proto_Services_V1_SealedDeviceMetadata(serializedBytes: blob)
        else { return nil }

        for copy in sealed.copies {
            guard let plaintext = try? openWithDeviceKey(
                sealedBox: [UInt8](copy),
                ourIdentityPriv: [UInt8](ourKey)
            ) else { continue }  // sealed to a sibling — the expected way to find our own
            return try? Shared_Proto_Services_V1_DeviceMetadata(serializedBytes: Data(plaintext))
        }
        return nil
    }

    // MARK: - When to publish

    /// The device set the last published blob was sealed for.
    ///
    /// Leaves with the account: it names this account's devices, and a stale marker after a
    /// re-registration would keep the new account from publishing at all.
    private static let publishedForKey = "construct.deviceMetadata.publishedFor.v1"

    /// Whether the set has moved since the last publish.
    ///
    /// The description itself changes only when a person renames the device; the set is what
    /// invalidates a blob, in both directions. A device added has no copy until we re-seal — that
    /// is the whole visible symptom, an unnamed row. A device removed keeps being able to read
    /// until we re-seal — that is the invisible one, and the reason this is not "publish when a
    /// device appears".
    nonisolated static func needsPublish(currentDeviceIds: [String], lastPublishedFor: [String]) -> Bool {
        guard !currentDeviceIds.isEmpty else { return false }  // unknown set — see `publish`
        return Set(currentDeviceIds) != Set(lastPublishedFor)
    }

    // MARK: - Publishing

    /// Re-seal and upload this device's metadata for the account's current device set.
    ///
    /// Called when the set changes, which is the only thing that invalidates a published blob: a
    /// device added has no copy until this runs, and a device removed keeps reading until it does.
    /// The description itself changes only when a person renames the device.
    @MainActor
    static func publish(myUserId: String, reason: String) async {
        guard !myUserId.isEmpty else { return }
        guard let ourPrivate = KeychainManager.shared.loadDeviceIdentityKey(), !ourPrivate.isEmpty else {
            Log.error("DeviceMetadata: no identity key in Keychain — not publishing (\(reason))", category: "DeviceLink")
            return
        }

        let devices = MultiDeviceSendCoordinator.shared.knownOwnDevices(myUserId: myUserId)
        guard !devices.isEmpty else {
            // Not "the account has no devices" — the cache is cold or the fetch failed. Publishing
            // now would replace a good blob with nothing.
            Log.info("DeviceMetadata: own-device set unknown — not publishing (\(reason))", category: "DeviceLink")
            return
        }

        let deviceIds = devices.map(\.deviceId)
        let lastPublishedFor = UserDefaults.standard.stringArray(forKey: publishedForKey) ?? []
        guard needsPublish(currentDeviceIds: deviceIds, lastPublishedFor: lastPublishedFor) else {
            Log.debug("DeviceMetadata: device set unchanged since last publish (\(reason))", category: "DeviceLink")
            return
        }

        guard let blob = seal(selfDescription(), toIdentityKeys: devices.map { Data($0.bundle.identityPublic) }) else {
            return
        }

        do {
            try await AuthServiceClient.shared.setDeviceMetadata(blob)
            // Recorded only after the server took it: a marker written on an attempt would make a
            // failed publish look done and skip every retry.
            UserDefaults.standard.set(deviceIds, forKey: publishedForKey)
            Log.info(
                "DeviceMetadata: published \(blob.count)B for \(devices.count) device(s) (\(reason))",
                category: "DeviceLink"
            )
        } catch {
            // Best effort: the list falls back to the device id, which is what it showed before
            // any of this existed. Retried on the next set change.
            Log.error("DeviceMetadata: publish failed (\(reason)): \(error)", category: "DeviceLink")
        }
    }
}
