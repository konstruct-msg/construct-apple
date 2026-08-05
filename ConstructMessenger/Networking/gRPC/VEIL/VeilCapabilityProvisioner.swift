//
//  VeilCapabilityProvisioner.swift
//  Construct Messenger
//
//  Auto first-issue of the veil-front B2 capability when none is stored (or the
//  stored one is expired/unparseable). Complements VeilCapabilityRenewer (near-
//  expiry refresh of an *existing* ticket) and VeilCapabilityV2Bootstrapper
//  (B1 key-bound, which still needs a B2 ticket to open the first tunnel).
//
//  Why this exists: OOB QR / paste is the cold-start fallback for a fully censored
//  network. When the client can reach the home server at all (direct path after
//  login, or any live transport), IssueVeilCapability is JWT-gated and must be
//  called automatically — testers should never have to import a ticket by hand
//  just because they signed in over clearnet. See
//  decisions/veil-ticket-provisioning-system.md + entry-directory-design.md.
//
//  Manual import (VeilConfigImporter) remains the reserve path.
//

import Foundation

@MainActor
final class VeilCapabilityProvisioner {
    static let shared = VeilCapabilityProvisioner()
    private init() {}

    /// Retry while we have never successfully provisioned (or after a failed attempt).
    /// Matches VeilCapabilityV2Bootstrapper's initial window — first RPC often races
    /// the direct→veil transport switch.
    private let initialRetryInterval: TimeInterval = 60
    /// After a successful provision, do not re-issue more often than this (expired
    /// tickets still re-enter via `needsProvision`; this only bounds hammering).
    private let postSuccessRetryInterval: TimeInterval = 60 * 60

    private var inFlight = false
    private var lastAttempt: Date?
    private var everSucceeded = false

    // MARK: - Pure decision (unit-tested)

    /// Whether the client needs a *first* (or replacement) B2 capability for this relay.
    ///
    /// - no ticket / empty → yes
    /// - unparseable (bad sig, wrong layout) → yes (re-issue; do not leave poison in store)
    /// - past `not_after` → yes
    /// - valid live ticket → no (near-expiry is `VeilCapabilityRenewer`'s job)
    ///
    /// `parse` is injectable so unit tests can exercise the expiry branch without
    /// holding the production issuer private key.
    ///
    /// `nonisolated` — pure decision over strings/dates; safe off the main actor and
    /// callable from unit tests without MainActor hops.
    nonisolated static func needsProvision(
        storedTicketB64: String?,
        now: Date = Date(),
        parse: (String) throws -> VeilConfigImporter.ParsedCapability = {
            try VeilConfigImporter.parseCapability($0)
        }
    ) -> Bool {
        guard let b64 = storedTicketB64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !b64.isEmpty else {
            return true
        }
        guard let parsed = try? parse(b64) else {
            return true
        }
        let nowU = UInt64(max(0, now.timeIntervalSince1970))
        if parsed.notAfter != 0 && nowU > parsed.notAfter {
            return true
        }
        return false
    }

    // MARK: - Opportunistic entry point

    /// Fire-and-forget. Safe to call frequently (launch, foreground, VEIL success,
    /// config refresh). No-ops when a live ticket is already stored, when there is
    /// no session token (RPC is JWT-gated), or when rate-limited.
    func provisionIfNeeded(relayAddress: String = VEILConfig.ruRelayAddress) {
        guard !inFlight else { return }

        let stored = VeilTicketStore.ticket(for: relayAddress)
        guard Self.needsProvision(storedTicketB64: stored) else { return }

        let retryInterval = everSucceeded ? postSuccessRetryInterval : initialRetryInterval
        if let last = lastAttempt, Date().timeIntervalSince(last) < retryInterval { return }

        // IssueVeilCapability is JWT-gated. Without a session the RPC only produces noise.
        guard KeychainManager.shared.loadSessionToken() != nil else {
            Log.debug("VEIL provision skipped — no session token yet", category: "VEIL")
            return
        }

        inFlight = true
        lastAttempt = Date()
        Log.info("VEIL provision: no live capability for \(relayAddress) — requesting first issue over active transport", category: "VEIL")

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let issued = try await VeilServiceClient.shared.issueCapability(relayAddress: relayAddress)
                // Backend returns B2 when veil_pk is omitted (capability_version == 1).
                // Accept any version whose blob verifies as a B2 layout for the ticket store;
                // key-bound v2 lives in VeilCapabilityV2Store and is handled by the bootstrapper.
                let newB64 = issued.capability.base64EncodedString()

                if issued.capabilityVersion == 2 {
                    // Unexpected for a bare request — do not poison the B2 store.
                    Log.error("VEIL provision: backend returned capability_version=2 without veil_pk request — not storing as B2", category: "VEIL")
                    return
                }

                let parsed = try VeilConfigImporter.parseCapability(newB64)
                guard VeilTicketStore.store(ticket: newB64, for: issued.relayAddress) else {
                    Log.error("VEIL provision: failed to store capability for \(issued.relayAddress)", category: "VEIL")
                    return
                }
                Log.info(
                    "VEIL provision: first capability stored for \(issued.relayAddress) (exp in \(Int((Double(parsed.notAfter) - Date().timeIntervalSince1970) / 86400))d)",
                    category: "VEIL"
                )

                let cachedAlts = VeilAlternatesCache.store(issued.alternates)
                if cachedAlts > 0 {
                    Log.info("VEIL provision: cached \(cachedAlts)/\(issued.alternates.count) alternate front(s)", category: "VEIL")
                }

                // Same anti-downgrade stance as the renewer: never override binary-pinned SPKI.
                if let pin = VEILConfig.hardcodedRelaySPKIs[issued.relayAddress],
                   !issued.spki.isEmpty, pin.lowercased() != issued.spki.lowercased() {
                    Log.error(
                        "VEIL provision: relay \(issued.relayAddress) reports SPKI \(issued.spki.prefix(12))… ≠ binary pin \(pin.prefix(12))… — cert rotated; ship an app update with the new pin",
                        category: "VEIL"
                    )
                }

                await MainActor.run {
                    self?.everSucceeded = true
                    // B2 is now present — kick B1 bootstrap over the same transport.
                    VeilCapabilityV2Bootstrapper.shared.bootstrapOrRenewIfNeeded(
                        relayAddress: issued.relayAddress
                    )
                }
            } catch {
                Log.error("VEIL provision failed for \(relayAddress): \(error)", category: "VEIL")
            }
        }
    }

    // MARK: - Test hooks

    #if DEBUG
    func resetForTesting() {
        inFlight = false
        lastAttempt = nil
        everSucceeded = false
    }
    #endif
}
