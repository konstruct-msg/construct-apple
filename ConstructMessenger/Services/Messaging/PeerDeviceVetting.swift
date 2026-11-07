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

    /// The devices of the answer the core can judge: those whose bundle carries the hybrid key and
    /// its binding. A device without them cannot open a session with anyone (the core requires PQ),
    /// so it can receive nothing yet. It stays unjudged, and the answer that brings its keys judges it.
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

    /// The devices this round of verdicts settles. `keyChanged` and `invalid` settle nothing, and an
    /// alarm nobody could raise is owed: the contact's row may not exist yet.
    static func judged(offered: [OfferedPeerDevice], verdicts: [PeerDeviceVerdict], alarmNotRaised: Set<String>) -> [String] {
        zip(offered, verdicts).compactMap { device, verdict in
            switch verdict {
            case .pinned, .firstOfAccount, .vouched:
                return device.deviceId
            case .unvouched:
                return alarmNotRaised.contains(device.deviceId) ? nil : device.deviceId
            case .keyChanged, .invalid:
                return nil
            }
        }
    }

    typealias Judge = @Sendable ([String], [OfferedPeerDevice]) -> [PeerDeviceVerdict]?
    typealias RaiseAlarm = @Sendable (String) async -> Bool

    private static let coreJudge: Judge = { CryptoManager.shared.judgePeerDevices(trustedDeviceIds: $0, offered: $1) }
    private static let raiseOnContact: RaiseAlarm = { accountId in
        await MainActor.run { KeyChangeUX.raise(.unvouchedDevice, userId: accountId) }
    }

    /// Record a `GetPreKeyBundles` answer and judge it, in the order that makes the verdict mean
    /// something: what was trusted is read **before** the answer is recorded.
    ///
    /// Only a full answer is judged: one narrowed to some device ids may leave out the device that
    /// signed the others, and they would read as unvouched when they are not.
    static func recordAnswer(
        ofPeer accountId: String,
        bundles: [DeviceBundleData],
        activeSet: [String],
        isFullAnswer: Bool,
        judge: Judge = coreJudge,
        raiseAlarm: RaiseAlarm = raiseOnContact
    ) async {
        let trustedBefore = PeerDeviceJudgement.trusted(ofPeer: accountId)
        let pins = bundles.map { (deviceId: $0.deviceId, identityKey: $0.bundle.identityPublic) }
        // Written before returning, not fired off: the caller's next move is usually to act on
        // these devices, and a write that lands after that would leave the first use of a
        // newly-linked device reading an incomplete set. This function is not on the main actor.
        SessionAddressing.reconcileDevices(pins, activeSet: activeSet, ofPeer: accountId)
        guard isFullAnswer, let trustedBefore else { return }
        await vet(accountId: accountId, bundles: bundles, trustedBefore: trustedBefore, judge: judge, raiseAlarm: raiseAlarm)
    }

    private static func vet(
        accountId: String,
        bundles: [DeviceBundleData],
        trustedBefore: [String],
        judge: Judge,
        raiseAlarm: RaiseAlarm
    ) async {
        guard await !MainActor.run(body: { SessionAddressing.isOurOwnAccount(accountId) }) else { return }
        let offered = offered(bundles)
        // Core down: no verdict and no mark, so these devices are judged on a later answer.
        guard !offered.isEmpty, let verdicts = judge(trustedBefore, offered) else { return }
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
        var alarmNotRaised: Set<String> = []
        if !alarm.isEmpty {
            Log.error(
                "device_cert UNVOUCHED \(alarm.map { $0.prefix(8) + "…" }.joined(separator: ",")) of \(accountId.prefix(8))…",
                category: "Crypto"
            )
            if await !raiseAlarm(accountId) { alarmNotRaised = Set(alarm) }
        }
        let settled = judged(offered: offered, verdicts: verdicts, alarmNotRaised: alarmNotRaised)
        let newlySettled = settled.filter { !trustedBefore.contains($0) }
        if !newlySettled.isEmpty {
            Log.info(
                "device_cert judged \(newlySettled.map { $0.prefix(8) + "…" }.joined(separator: ",")) of \(accountId.prefix(8))…",
                category: "Crypto"
            )
        }
        PeerDeviceJudgement.mark(settled)
    }
}
