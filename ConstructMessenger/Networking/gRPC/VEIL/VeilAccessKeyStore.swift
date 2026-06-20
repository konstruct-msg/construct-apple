//
//  VeilAccessKeyStore.swift
//  Construct Messenger
//
//  Per-device Ed25519 access keypair (`veil_sk`/`veil_pk`) for ticket-B1's key-bound
//  veil-front capability (AUTH v3). Generated locally on first use and never sent to
//  the relay or backend — only `veil_pk` ever leaves the device, as part of
//  IssueVeilCapability's request. See decisions/veil-ticket-provisioning-system.md (B1).
//

import Foundation
import CryptoKit

/// Stores the device's own veil-front access keypair. `veil_start` can run on a
/// push-driven background wake before the user unlocks the device (same reasoning as
/// `VeilTicketStore`), so this uses the same `AfterFirstUnlockThisDeviceOnly` class
/// rather than `WhenUnlocked`.
final class VeilAccessKeyStore {
    static let shared = VeilAccessKeyStore()
    private init() {}

    private static let keychainKey = "veil_access_key"

    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?

    /// The device's `veil_sk` (32-byte Ed25519 seed), generating and persisting one on
    /// first access if none exists yet.
    var veilSk: Data {
        privateKey.rawRepresentation
    }

    /// The device's `veil_pk` (32-byte Ed25519 public key) matching `veilSk`.
    var veilPk: Data {
        privateKey.publicKey.rawRepresentation
    }

    var veilSkHex: String { veilSk.veilHexEncoded }
    var veilPkHex: String { veilPk.veilHexEncoded }

    private var privateKey: Curve25519.Signing.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }
        if let stored = KeychainManager.shared.loadData(forKey: Self.keychainKey),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) {
            cachedPrivateKey = key
            return key
        }
        let generated = Curve25519.Signing.PrivateKey()
        _ = KeychainManager.shared.saveData(
            generated.rawRepresentation, forKey: Self.keychainKey,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        cachedPrivateKey = generated
        Log.info("VEIL: generated new veil_sk/veil_pk access keypair", category: "VEIL")
        return generated
    }
}

extension Data {
    /// Lowercase hex encoding.
    var veilHexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
