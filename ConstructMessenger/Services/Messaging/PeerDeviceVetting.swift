//
//  PeerDeviceVetting.swift
//  Construct Messenger
//
//  Is every device of a contact's account vouched for by one we already trust?
//  `construct-docs/decisions/devices-of-an-account-sign-each-other.md`.
//
//  The verdict is the core's (`judgePeerDevices`): the same on every client, so this file only
//  translates — the account to the devices we pinned for it, the bundles to what the core takes —
//  and raises the alarm on what comes back. Only the alarm: an unvouched device still receives
//  copies (owner, 2026-10-23).
//

import Foundation

enum PeerDeviceVetting {

    /// The devices of the answer the core should judge: those whose bundle carries the hybrid key
    /// and its binding. A device without them cannot open a session with anyone (the core requires
    /// PQ), so it can receive nothing and is not worth an alarm.
    static func offered(_ bundles: [DeviceBundleData]) -> [OfferedPeerDevice] {
        bundles.compactMap { entry in
            DeviceCertificateIssuer.subjectKeys(from: entry).map {
                OfferedPeerDevice(deviceId: entry.deviceId, keys: $0, certificate: entry.deviceCertificate)
            }
        }
    }

    /// The devices to alarm about: unvouched, and not already trusted here — a device the user was
    /// warned about once and kept is pinned by then, and the next fetch reads it as `pinned`.
    static func unvouched(trusted: [String], offered: [OfferedPeerDevice], verdicts: [PeerDeviceVerdict]) -> [String] {
        let known = Set(trusted)
        return zip(offered, verdicts).compactMap { device, verdict in
            guard case .unvouched = verdict, !known.contains(device.deviceId) else { return nil }
            return device.deviceId
        }
    }

    /// Judge a full answer for `accountId`, against the devices trusted **before** this answer was
    /// recorded — after it, every device it names is pinned and nothing could ever be new.
    ///
    /// Only a full answer: one narrowed to some device ids may leave out the device that signed
    /// the others, and they would read as unvouched when they are not.
    static func vet(accountId: String, bundles: [DeviceBundleData], trustedBefore: [String]) async {
        guard await !MainActor.run(body: { SessionAddressing.isOurOwnAccount(accountId) }) else { return }
        let offered = offered(bundles)
        guard !offered.isEmpty,
              let verdicts = CryptoManager.shared.judgePeerDevices(trustedDeviceIds: trustedBefore, offered: offered)
        else { return }
        for (device, verdict) in zip(offered, verdicts) {
            switch verdict {
            case .keyChanged:
                Log.error("device_cert device=\(device.deviceId.prefix(8))… of \(accountId.prefix(8))… presents another hybrid key", category: "Crypto")
            case .invalid:
                Log.error("device_cert device=\(device.deviceId.prefix(8))… of \(accountId.prefix(8))… bundle does not hold together", category: "Crypto")
            default:
                break
            }
        }
        let alarm = unvouched(trusted: trustedBefore, offered: offered, verdicts: verdicts)
        guard !alarm.isEmpty else { return }
        Log.error(
            "device_cert UNVOUCHED \(alarm.map { $0.prefix(8) + "…" }.joined(separator: ",")) of \(accountId.prefix(8))…",
            category: "Crypto"
        )
        await MainActor.run { _ = KeyChangeUX.raise(.unvouchedDevice, userId: accountId) }
    }
}
