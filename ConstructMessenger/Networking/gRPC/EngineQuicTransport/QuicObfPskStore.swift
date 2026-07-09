//
//  QuicObfPskStore.swift
//  Construct Messenger
//
//  Per-gateway Salamander obfuscation PSK store (Keychain). The PSK is a SHARED
//  per-gateway secret (one for all of a gateway's users), provisioned out-of-band as a
//  signed field in the veil config blob — NOT a per-user / per-capability key. It only
//  drives the Salamander keystream (obfuscation / probing-resistance), never authentication
//  (that stays in QUIC TLS + the gRPC JWT + the VEIL capability + message E2EE).
//  See decisions/salamander-psk-shared-per-gateway.md.
//

import Foundation

enum QuicObfPskStore {
    private static func key(for gatewayHost: String) -> String { "quic_obf_psk.\(gatewayHost)" }

    /// The Salamander PSK for `gatewayHost`, or nil if none provisioned.
    static func psk(for gatewayHost: String) -> Data? {
        guard let data = KeychainManager.shared.loadData(forKey: key(for: gatewayHost)),
              !data.isEmpty else { return nil }
        return data
    }

    @discardableResult
    static func store(psk: Data, for gatewayHost: String) -> Bool {
        // AfterFirstUnlockThisDeviceOnly — the obfuscated transport may start on a push-driven
        // background wake before the user unlocks the device (same as the veil ticket).
        KeychainManager.shared.saveData(
            psk, forKey: key(for: gatewayHost),
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func clear(for gatewayHost: String) {
        KeychainManager.shared.deleteData(forKey: key(for: gatewayHost))
    }
}
