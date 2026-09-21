//
//  BundleSigningTrust.swift
//  Construct Messenger
//
//  The keys this client accepts a server-side Ed25519 signature from: sender certificates,
//  prekey bundles, and now sticker-pack manifests are all signed with the one key deployed as
//  BUNDLE_SIGNING_KEY. One resolution, three verifiers — a fourth signature scheme would read
//  from here too, so that a rotation is handled in one place.
//

import CryptoKit
import Foundation

enum BundleSigningTrust {
    /// In preference order: the key fetched from `/.well-known/construct-server` (if cached),
    /// then the build-time pins (`VEILConfig.pinnedBundleSigningKeys`). The pins are
    /// sealed-sender-resilience lever B — they keep verification possible when the fetched key
    /// was never cached or after a rotation.
    static func trustedKeys(extra: [Data] = []) -> [Curve25519.Signing.PublicKey] {
        var raw: [Data] = []
        if let fetched = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey) {
            raw.append(fetched)
        }
        for b64 in VEILConfig.pinnedBundleSigningKeys {
            if let d = Data(base64Encoded: b64) { raw.append(d) }
        }
        raw.append(contentsOf: extra)
        return raw.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// True when any trusted key verifies `signature` over `message`.
    static func verify(signature: Data, over message: Data, keys: [Curve25519.Signing.PublicKey]) -> Bool {
        keys.contains { $0.isValidSignature(signature, for: message) }
    }
}
