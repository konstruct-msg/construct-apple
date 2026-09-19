//
//  DeviceLinkPendingPin.swift
//  Construct Messenger
//
//  What the link QR pinned, kept until history finishes or is skipped.
//  Not a PAKE. Flow A: the new device pins the offering device's `fp`.
//  Flow B: the offering device pins the new device's X25519 `pubkey`;
//  the new device is bound to the directory only — the named residual.
//

import Foundation

/// What the receiving side of a history transfer may hold against the offering device.
enum HistoryQRPin: Equatable {
    /// Flow A: `fp` = SHA256(identity ‖ hybrid) of the offering device from the link QR.
    case pinned(Data)
    /// Flow B: this device showed the QR, so the offering device is known from the
    /// directory only. Logged as `bundle_only`; accepted (spec K16 residual, v1.1 closes it).
    case bundleOnly
    /// Flow A with a QR that carried no `fp`: link proceeds, history is refused.
    case absent
}

enum DeviceLinkPendingPin {
    private static let tokenPrefix = "ct.device_link.fp.token."
    private static let userPrefix = "ct.device_link.fp.user."
    private static let bundleOnlyPrefix = "ct.device_link.bundle_only.user."
    private static let peerIdentityPrefix = "ct.device_link.peer_identity.device."

    // MARK: Flow A — new device holds the offering device's fp

    static func store(_ fp: Data, forToken token: String) {
        guard fp.count == 32, !token.isEmpty else { return }
        UserDefaults.standard.set(fp, forKey: tokenPrefix + token)
    }

    static func load(forToken token: String) -> Data? {
        UserDefaults.standard.data(forKey: tokenPrefix + token)
    }

    static func bindToAccount(userId: String, fromToken token: String) {
        if let fp = load(forToken: token), !userId.isEmpty {
            UserDefaults.standard.set(fp, forKey: userPrefix + userId)
        }
        clear(forToken: token)
    }

    static func load(forUserId userId: String) -> Data? {
        UserDefaults.standard.data(forKey: userPrefix + userId)
    }

    // MARK: Flow B — new device showed the QR; nothing to pin, and that is recorded

    static func markBundleOnly(userId: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: bundleOnlyPrefix + userId)
    }

    /// The trust this device holds against the offering device, for the verifiers.
    static func trust(forUserId userId: String) -> HistoryQRPin {
        if let fp = load(forUserId: userId) { return .pinned(fp) }
        if UserDefaults.standard.bool(forKey: bundleOnlyPrefix + userId) { return .bundleOnly }
        return .absent
    }

    // MARK: Flow B — offering device holds the new device's X25519 identity

    static func storePeerIdentity(_ identityPublic: Data, forDeviceId deviceId: String) {
        guard identityPublic.count == 32, !deviceId.isEmpty else { return }
        UserDefaults.standard.set(identityPublic, forKey: peerIdentityPrefix + deviceId)
    }

    /// nil = Flow A on the offering side: our QR was scanned, the new device is directory-only.
    static func peerIdentity(forDeviceId deviceId: String) -> Data? {
        UserDefaults.standard.data(forKey: peerIdentityPrefix + deviceId)
    }

    // MARK: Clear

    static func clear(forToken token: String) {
        UserDefaults.standard.removeObject(forKey: tokenPrefix + token)
    }

    static func clear(forUserId userId: String) {
        UserDefaults.standard.removeObject(forKey: userPrefix + userId)
        UserDefaults.standard.removeObject(forKey: bundleOnlyPrefix + userId)
    }

    static func clearPeerIdentity(forDeviceId deviceId: String) {
        UserDefaults.standard.removeObject(forKey: peerIdentityPrefix + deviceId)
    }
}
