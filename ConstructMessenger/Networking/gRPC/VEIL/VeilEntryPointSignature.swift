//
//  VeilEntryPointSignature.swift
//  Construct Messenger
//
//  Phase 3 of the signed-front-trust plan: an `EntryPoint`'s coordinates arrive with
//  an Ed25519 signature by the issuer key, so a front can be offered without existing
//  in the published manifest or in this binary.
//
//  Until this landed, `VeilAlternatesCache` could only accept an address some *public*
//  artifact already vouched for, which meant offering an alternate front required
//  publishing it. Since `select_alternate_addresses` excludes the primary and the
//  manifest carries no relays, every alternate was in practice rejected as
//  `unknownRelay` — EntryDirectory v1 issued capabilities nobody could use.
//
//  Signed bytes are the coordinate tuple and nothing else:
//
//      {"exp":<i64>,"relay":"<host:port>","sni":"<sni>","spki":"<hex sha256 spki>"}
//
//  compact, keys sorted, slashes unescaped — the same canonicalisation as the voucher
//  blob (`VeilConfigImporter.verifySignature`), which is why the server signs both with
//  one helper. The capability is deliberately **not** in the tuple: it is verified on
//  its own, and including it would make the signature unusable for a rotated capability
//  on the same coordinates.
//
//  See construct-docs/backend/VEIL_SIGNED_ENTRYPOINT_SPEC.md.
//

import Foundation
import CryptoKit

enum VeilEntryPointSignature {

    /// True when `signature` is a valid `ed25519:<base64url>` over the canonical tuple.
    ///
    /// `publicKeyHex` is injectable so tests can sign with a key they hold; production
    /// callers take the default — the same pinned key that anchors the relay manifest
    /// and the bootstrap voucher.
    static func verify(
        signature: String,
        relay: String,
        sni: String,
        spki: String,
        exp: Int64,
        publicKeyHex: String = VEILConfig.relayConfigSigningKey
    ) -> Bool {
        guard signature.hasPrefix("ed25519:") else { return false }
        guard let sigData = Data(
            veilBase64URLEncoded: String(signature.dropFirst("ed25519:".count))
        ) else { return false }
        guard !relay.isEmpty, !sni.isEmpty, !spki.isEmpty else { return false }
        guard let canonical = canonicalTuple(relay: relay, sni: sni, spki: spki, exp: exp),
              let pubKeyData = Data(veilHexString: publicKeyHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)
        else { return false }
        return publicKey.isValidSignature(sigData, for: canonical)
    }

    /// The exact bytes the issuer signed. Exposed for tests, which need to produce them.
    static func canonicalTuple(relay: String, sni: String, spki: String, exp: Int64) -> Data? {
        let object: [String: Any] = [
            "exp": NSNumber(value: exp),
            "relay": relay,
            "sni": sni,
            "spki": spki,
        ]
        return try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
