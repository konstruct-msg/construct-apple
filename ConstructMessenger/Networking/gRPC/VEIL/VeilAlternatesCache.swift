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
    ///
    /// The three gates live in `VeilRelayTrust` so the primary-capability path applies the
    /// same ones — it used to apply strictly weaker checks to a coordinate the server picks.
    static func accept(_ alt: VeilServiceClient.Alternate) -> Bool {
        let rejection = VeilRelayTrust.verify(
            relayAddress: alt.relayAddress,
            spki: alt.spki,
            capabilityB64: alt.capability.base64EncodedString(),
            capabilityVersion: alt.capabilityVersion
        )
        guard let rejection else { return true }
        switch rejection {
        case .unknownRelay:
            // Expected during manifest rotation, not an error: the server offered a front
            // this build has no anchor for, and we simply do not take it.
            Log.info("VEIL alt: reject \(alt.relayAddress) — \(rejection.summary)", category: "VEIL")
        case .spkiMismatch, .invalidCapability:
            Log.error("VEIL alt: reject \(alt.relayAddress) — \(rejection.summary)", category: "VEIL")
        }
        return false
    }
}
