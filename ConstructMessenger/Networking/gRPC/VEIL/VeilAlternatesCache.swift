//
//  VeilAlternatesCache.swift
//  Construct Messenger
//
//  EntryDirectory v1 (Source 1) — validate and cache the pre-issued **alternate
//  fronts** returned alongside a primary capability by VeilService.IssueVeilCapability.
//
//  Trust model (decisions/entry-directory-design.md, Option C — signed manifest):
//  an alternate's coordinates are asserted by the *server*, which is the adversary in
//  our threat model, so they are NOT trusted on their own. An alternate is accepted
//  only when
//    1. its address is vouched for by a trust anchor NOT under the live server's
//       control — the Ed25519-signed relay manifest (VeilCertFetcher, verified against
//       relayConfigSigningKey) or the in-binary pin set, AND
//    2. the SPKI in the response matches that trusted pin (anti-redirection: the server
//       cannot push a relay/pin the signed manifest doesn't already vouch for), AND
//    3. the capability blob itself carries a valid issuer signature and live window.
//  This preserves the existing anti-redirection invariant (VeilConfigImporter rejects
//  unknown relays) while letting the relay set rotate without an app update.
//
//  A cached alternate becomes usable automatically: the relay pool is built from the
//  signed manifest, so on primary-front failure the selector rotates to the alternate
//  and its capability is already in the Keychain — no round-trip to the dead front.
//

import Foundation

enum VeilAlternatesCache {

    /// Validate and cache each alternate. Returns the number actually stored.
    @discardableResult
    static func store(_ alternates: [VeilServiceClient.Alternate]) -> Int {
        var stored = 0
        for alt in alternates {
            guard accept(alt) else { continue }
            let b64 = alt.capability.base64EncodedString()
            let ok: Bool
            switch alt.capabilityVersion {
            case 2:  ok = VeilCapabilityV2Store.store(capability: b64, for: alt.relayAddress)
            default: ok = VeilTicketStore.store(ticket: b64, for: alt.relayAddress)
            }
            if ok {
                stored += 1
                Log.info("VEIL alt: cached front \(alt.relayAddress) (v\(alt.capabilityVersion))", category: "VEIL")
            } else {
                Log.error("VEIL alt: failed to persist capability for \(alt.relayAddress)", category: "VEIL")
            }
        }
        return stored
    }

    /// The Option-C acceptance gate for a single alternate. Exposed for tests.
    static func accept(_ alt: VeilServiceClient.Alternate) -> Bool {
        // 1. Coords must be vouched for by a trust anchor the live server does not
        //    control: the signed relay manifest, or the in-binary pin.
        let trusted = VeilCertFetcher.spkiPinSync(for: alt.relayAddress)
            ?? VEILConfig.hardcodedRelaySPKIs[alt.relayAddress]
        guard let trustedSpki = trusted, !trustedSpki.isEmpty else {
            Log.info("VEIL alt: reject \(alt.relayAddress) — not in signed manifest or pin set", category: "VEIL")
            return false
        }

        // 2. Response SPKI must match the trusted pin (anti-redirection).
        guard !alt.spki.isEmpty, trustedSpki.lowercased() == alt.spki.lowercased() else {
            Log.error("VEIL alt: reject \(alt.relayAddress) — SPKI \(alt.spki.prefix(12))… ≠ trusted \(trustedSpki.prefix(12))…", category: "VEIL")
            return false
        }

        // 3. The capability must carry a valid issuer signature + live window (the same
        //    offline check the relay performs).
        let b64 = alt.capability.base64EncodedString()
        do {
            switch alt.capabilityVersion {
            case 2:  _ = try VeilConfigImporter.parseCapabilityV2(b64)
            default: _ = try VeilConfigImporter.parseCapability(b64)
            }
        } catch {
            Log.error("VEIL alt: reject \(alt.relayAddress) — invalid capability: \(error)", category: "VEIL")
            return false
        }

        return true
    }
}
