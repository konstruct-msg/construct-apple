//
//  VeilCapabilityV2Bootstrapper.swift
//  Construct Messenger
//
//  Ticket-B1 bootstrap + renewal for the key-bound veil-front capability (AUTH v3).
//
//  Bootstrap (chicken-egg, per decisions/veil-ticket-provisioning-system.md §B1): the
//  holder can't get `veil_pk` signed without first reaching the issuer. We solve it the
//  same way the doc does — the existing B2 bearer capability (out-of-band QR/paste,
//  already working) brings up the veil tunnel once; over that live tunnel we call
//  IssueVeilCapability(veil_pk, role) to get the first CapabilityV2, verify it, and
//  store it. From then on `veil_start` is handed both: Rust prefers AUTH v3 when both
//  are present (`veil_front_adapter.rs`), falling back to the B2 ticket only if the v2
//  capability is missing/expired.
//
//  Mirrors VeilCapabilityRenewer's shape (in-flight guard, throttled opportunistic
//  retry) since renewal uses the exact same RPC, just re-presenting `veil_pk`.
//

import Foundation

@MainActor
final class VeilCapabilityV2Bootstrapper {
    static let shared = VeilCapabilityV2Bootstrapper()
    private init() {}

    /// Bootstrap/renew once the stored v2 capability has less than this remaining
    /// (or doesn't exist at all).
    private let renewWindow: TimeInterval = 14 * 24 * 3600   // 14 days
    /// Don't re-attempt routine renewal more often than this within a session.
    private let minRetryInterval: TimeInterval = 60 * 60      // 1 hour
    /// Retry interval while we've never successfully bootstrapped yet. The only call
    /// site today is `VeilProxyManager.startIfEnabled()`, which fires before
    /// `ConnectionLoop`/`TransportRouter` has actually brought the VEIL tunnel up — the
    /// first attempt routinely loses the race against the direct→veil-probing→veil-active
    /// transport switch (`invalidate-grpc` tears down the in-flight RPC). A short retry
    /// keeps the bootstrap from being stuck for a full hour after that expected first miss.
    private let initialBootstrapRetryInterval: TimeInterval = 60

    private var inFlight = false
    private var lastAttempt: Date?

    /// Opportunistic check. Safe to call frequently (e.g. alongside
    /// `VeilCapabilityRenewer.renewIfNeeded` on every confirmed VEIL RPC success and at
    /// launch) — no-ops unless a fresh v2 capability is needed and the retry interval
    /// has elapsed. Requires a B2 capability to already be present for `relayAddress`
    /// (the bootstrap precondition: there must be a working tunnel to call the RPC over).
    func bootstrapOrRenewIfNeeded(relayAddress: String) {
        guard !inFlight else { return }
        let hasBootstrapped = VeilCapabilityV2Store.capability(for: relayAddress) != nil
        let retryInterval = hasBootstrapped ? minRetryInterval : initialBootstrapRetryInterval
        if let last = lastAttempt, Date().timeIntervalSince(last) < retryInterval { return }

        guard VeilTicketStore.ticket(for: relayAddress) != nil else {
            return  // no B2 capability yet — nothing to bootstrap a tunnel from
        }

        if let storedB64 = VeilCapabilityV2Store.capability(for: relayAddress),
           let parsed = try? VeilConfigImporter.parseCapabilityV2(storedB64) {
            let now = UInt64(max(0, Date().timeIntervalSince1970))
            let secondsLeft = parsed.notAfter > now ? Double(parsed.notAfter - now) : 0
            guard secondsLeft < renewWindow else { return }   // not near expiry yet
        }
        // Else: nothing stored (or unparseable) — proceed to bootstrap.

        inFlight = true
        lastAttempt = Date()
        Log.info("VEIL B1: bootstrapping/renewing key-bound capability for \(relayAddress)", category: "VEIL")

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let veilPk = VeilAccessKeyStore.shared.veilPk
                let issued = try await VeilServiceClient.shared.issueCapability(
                    relayAddress: relayAddress,
                    veilPk: veilPk,
                    role: .user
                )
                guard issued.capabilityVersion == 2 else {
                    Log.error("VEIL B1: backend returned capability_version=\(issued.capabilityVersion), expected 2 — not storing", category: "VEIL")
                    return
                }
                let newB64 = issued.capability.base64EncodedString()

                // Validate the issuer signature + window + that the bound veil_pk is
                // actually ours before trusting it.
                let parsed = try VeilConfigImporter.parseCapabilityV2(newB64)
                guard parsed.veilPk == veilPk else {
                    Log.error("VEIL B1: returned capability is bound to an unexpected veil_pk — not storing", category: "VEIL")
                    return
                }

                guard VeilCapabilityV2Store.store(capability: newB64, for: issued.relayAddress) else {
                    Log.error("VEIL B1: failed to store capability for \(issued.relayAddress)", category: "VEIL")
                    return
                }
                Log.info("VEIL B1: capability ready for \(issued.relayAddress) (exp in \(Int((Double(parsed.notAfter) - Date().timeIntervalSince1970) / 86400))d)", category: "VEIL")
            } catch {
                Log.error("VEIL B1 bootstrap/renew failed for \(relayAddress): \(error)", category: "VEIL")
            }
        }
    }
}
