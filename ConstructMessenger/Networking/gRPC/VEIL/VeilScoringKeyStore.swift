//
//  VeilScoringKeyStore.swift
//  Construct Messenger
//
//  A random 32-byte device key that keys the scores fingerprint hash (HMAC-SHA256)
//  inside construct-veil, so the SQLite scores DB stores opaque blobs rather than a
//  readable SSID/BSSID history. Generated locally on first use and never sent anywhere.
//

import Foundation
import CryptoKit

/// The device's scoring key. `veil_start` can run on a push-driven background wake
/// before unlock, so this uses the same `AfterFirstUnlockThisDeviceOnly` class as
/// `VeilAccessKeyStore`.
final class VeilScoringKeyStore: Sendable {
    static let shared = VeilScoringKeyStore()
    private init() {}

    private static let keychainKey = "veil_scores_key"

    /// The 32-byte scoring key, generating and persisting one on first access.
    var scoringKey: Data {
        if let stored = KeychainManager.shared.loadData(forKey: Self.keychainKey),
           stored.count == 32 {
            return stored
        }
        let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        _ = KeychainManager.shared.saveData(
            generated, forKey: Self.keychainKey,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        Log.info("VEIL: generated a new scores-fingerprint key", category: "VEIL")
        return generated
    }
}
