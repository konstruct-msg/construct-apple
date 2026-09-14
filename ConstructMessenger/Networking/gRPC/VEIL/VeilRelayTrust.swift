//
//  VeilRelayTrust.swift
//  Construct Messenger
//
//  The Option-C acceptance gate for *any* relay coordinate the server hands us —
//  the pre-issued alternates and the primary capability alike.
//
//  It exists as one function because the two paths had drifted apart. The alternates
//  path (`VeilAlternatesCache.accept`) applied all three gates and had four tests for
//  the rejections; the primary path (`VeilCapabilityProvisioner.provisionIfNeeded`)
//  checked the issuer signature, stored the ticket, and only *then* compared the SPKI
//  against the binary pin — as a log line, with the ticket already in the Keychain —
//  and skipped that comparison entirely when the address was in neither the signed
//  manifest nor the pin set, because the check sat inside `if let pin = …`.
//
//  That asymmetry mattered more than a duplicated guard usually does. The address is
//  taken from the *response* (`VeilServiceClient.issueCapability` prefers
//  `response.relay_address` over the one we asked for), and the server is the adversary
//  in this threat model: answering a request for relay A with relay B stored a ticket
//  for B with no coordinate check at all. The alternates path rejects exactly that
//  (`testAlternatesAccept_rejectsUnknownRelay`); the primary path had no test, which is
//  why the divergence was silent.
//
//  Trust model: decisions/entry-directory-design.md (Option C — signed manifest) and
//  decisions/server-influence-minimization.md.
//

import Foundation

enum VeilRelayTrust {

    /// Why a relay coordinate was refused. Carried rather than logged inline so callers
    /// can phrase it for their own path and tests can assert the *reason*, not just the no.
    enum Rejection: Equatable {
        /// No trust anchor outside the live server's control vouches for this address.
        case unknownRelay
        /// The response SPKI disagrees with the trusted pin, or is absent.
        case spkiMismatch(trusted: String, offered: String)
        /// The capability blob failed its issuer-signature / live-window check.
        case invalidCapability(String)

        /// Stable, low-cardinality label for metrics — never the address or a key, which
        /// would turn a local counter into a record of where this user was steered.
        var metricLabel: String {
            switch self {
            case .unknownRelay:      return "unknown_relay"
            case .spkiMismatch:      return "spki_mismatch"
            case .invalidCapability: return "invalid_capability"
            }
        }

        var summary: String {
            switch self {
            case .unknownRelay:
                return "not in signed manifest, pin set or learned fronts"
            case .spkiMismatch(let trusted, let offered):
                let offeredText = offered.isEmpty ? "<empty>" : String(offered.prefix(12)) + "…"
                return "SPKI \(offeredText) ≠ trusted \(trusted.prefix(12))…"
            case .invalidCapability(let detail):
                return "invalid capability: \(detail)"
            }
        }
    }

    /// Accept a relay coordinate + capability, or say why not.
    ///
    /// All three gates, in order, on every path:
    ///  1. the address is vouched for by an anchor the live server does not control —
    ///     the Ed25519-signed relay manifest, the in-binary pin set, or a front this
    ///     device learned from a blob signed by `relayConfigSigningKey`;
    ///  2. the offered SPKI matches that anchor (anti-redirection);
    ///  3. the capability carries a valid issuer signature and live window — the same
    ///     offline check the relay itself performs.
    static func verify(
        relayAddress: String,
        spki: String,
        capabilityB64: String,
        capabilityVersion: UInt32
    ) -> Rejection? {
        let trusted = VeilCertFetcher.spkiPinSync(for: relayAddress)
            ?? VEILConfig.hardcodedRelaySPKIs[relayAddress]
            ?? learnedPin(relayAddress)
        guard let trustedSpki = trusted, !trustedSpki.isEmpty else {
            return .unknownRelay
        }
        guard !spki.isEmpty, trustedSpki.lowercased() == spki.lowercased() else {
            return .spkiMismatch(trusted: trustedSpki, offered: spki)
        }
        do {
            switch capabilityVersion {
            case 2:  _ = try VeilConfigImporter.parseCapabilityV2(capabilityB64)
            default: _ = try VeilConfigImporter.parseCapability(capabilityB64)
            }
        } catch {
            return .invalidCapability("\(error)")
        }
        return nil
    }

    /// `verify`, plus the fourth anchor: an issuer signature over the coordinate tuple.
    ///
    /// This is what lets a front be *offered* rather than published. When nothing public
    /// vouches for the address, a valid `ed25519:` signature by `relayConfigSigningKey`
    /// over `{exp, relay, sni, spki}` does — and the front is written to the learned
    /// store so later dials of the same address find a pin without another round-trip.
    ///
    /// A signature never overrides a public anchor. If the manifest or the binary already
    /// pins this address, that pin decides and a signed tuple offering a different SPKI
    /// still fails gate 2 — otherwise the live server could re-point a published front by
    /// signing over it, which is the whole thing the manifest exists to prevent.
    ///
    /// The pin is written *before* the capability check and rolled back if that check
    /// fails, mirroring `VeilConfigImporter.importBlob`: refusing a coordinate must not
    /// leave a trusted address behind.
    ///
    /// `publicKeyHex` is injectable for tests only — they cannot sign with the pinned
    /// key, and without it the signature branch could never be reached under test.
    static func verifyAndLearn(
        relayAddress: String,
        spki: String,
        sni: String,
        notAfter: Int64,
        signature: String,
        capabilityB64: String,
        capabilityVersion: UInt32,
        now: Date = Date(),
        publicKeyHex: String = VEILConfig.relayConfigSigningKey
    ) -> Rejection? {
        let hasPublicAnchor = VeilCertFetcher.spkiPinSync(for: relayAddress) != nil
            || VEILConfig.hardcodedRelaySPKIs[relayAddress] != nil
        let alreadyLearned = VeilLearnedFrontStore.shared.pin(for: relayAddress) != nil

        var provisional = false
        if !hasPublicAnchor, !alreadyLearned,
           notAfter > Int64(now.timeIntervalSince1970),
           VeilEntryPointSignature.verify(
               signature: signature,
               relay: relayAddress,
               sni: sni,
               spki: spki,
               exp: notAfter,
               publicKeyHex: publicKeyHex
           ) {
            provisional = VeilLearnedFrontStore.shared.save(
                address: relayAddress, sni: sni, spki: spki
            )
        }

        let rejection = verify(
            relayAddress: relayAddress,
            spki: spki,
            capabilityB64: capabilityB64,
            capabilityVersion: capabilityVersion
        )
        if rejection != nil, provisional {
            VeilLearnedFrontStore.shared.remove(relayAddress)
        }
        return rejection
    }

    /// The third anchor: a front this device learned from a signature.
    ///
    /// Consulted last so a bundled or manifest pin still wins for a seed relay — order
    /// is otherwise irrelevant to security, since all three yield a pin that must then
    /// equal the offered SPKI. This does not widen trust on its own: the store is only
    /// ever written by a path that has already verified an Ed25519 signature over the
    /// coordinate tuple (`VeilConfigImporter.importBlob`, `verifyAndLearn` above).
    ///
    /// Deliberately per-address. See `VeilLearnedFrontStore` for why a learned pin must
    /// never join the address-free `VeilLocalDiscovery.trustedSPKIs()` set.
    private static func learnedPin(_ relayAddress: String) -> String? {
        VeilLearnedFrontStore.shared.pin(for: relayAddress)
    }
}
