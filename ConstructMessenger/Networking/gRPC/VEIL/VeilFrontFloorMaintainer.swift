//
//  VeilFrontFloorMaintainer.swift
//  Construct Messenger
//
//  Keeps the device holding at least `floor` **usable** fronts, so losing one never
//  leaves it on a single point of failure between the slow renewals.
//
//  The acquisition machinery already exists: `IssueVeilCapability` returns a primary
//  plus up to K signed alternates, `VeilRelayTrust.verifyAndLearn` accepts each one by
//  its issuer signature (no manifest/seed entry needed), and `VeilAlternatesCache`
//  caches them so the selector can fail over without a round-trip to a dead front. What
//  was missing is a *reactive* top-up: alternates were only refreshed on first-issue
//  (`VeilCapabilityProvisioner`) and near-expiry (`VeilCapabilityRenewer`, <14d of a 60d
//  capability → roughly every ~46 days). A front blocked today with a fresh capability
//  was never replaced until that distant renewal.
//
//  This fills exactly that gap and nothing more. It is add-only: a blocked front is
//  never deleted — its pin stays in the learned store and it simply stops counting
//  toward the floor while unavailable — so eviction can never be censor-triggered into
//  permanent loss. The decision reads only live session state (stored capabilities +
//  the address just reported unavailable); nothing about "front X is dead on network Y"
//  is persisted.
//
//  Decision: construct-docs decisions/veil-front-topup-keep-two-usable.md.
//

import Foundation

@MainActor
final class VeilFrontFloorMaintainer {
    static let shared = VeilFrontFloorMaintainer()
    private init() {}

    /// Target number of usable fronts to keep on hand.
    nonisolated static let floor = 2

    /// Floor between top-up issuance attempts. The top-up is not urgent (it only matters
    /// before the *next* front also fails), so pace it well above the RPC-success tick.
    private let retryInterval: TimeInterval = 120
    private var inFlight = false
    private var lastAttempt: Date?

    // MARK: - Pure decision (unit-tested)

    /// Number of distinct usable fronts among `candidates`. A front is usable when it
    /// holds a live (non-expired, parseable) B2 capability and is not in `excluding`
    /// (used to drop a front we just saw fail, so a capped-but-blocked front cannot mask
    /// the shortage). `nonisolated` + injectable `hasLiveCap` so it is testable off the
    /// main actor without the Keychain.
    nonisolated static func usableCount(
        candidates: [String],
        excluding: Set<String> = [],
        hasLiveCap: (String) -> Bool
    ) -> Int {
        var seen = Set<String>()
        var count = 0
        for address in candidates
        where !address.isEmpty && !excluding.contains(address) && seen.insert(address).inserted {
            if hasLiveCap(address) { count += 1 }
        }
        return count
    }

    nonisolated static func isBelowFloor(_ usable: Int) -> Bool { usable < floor }

    /// Does this address hold a live B2 capability? (Same test `VeilCapabilityProvisioner`
    /// uses, negated — missing/expired/unparseable ⇒ not usable.)
    nonisolated static func hasLiveCap(_ address: String) -> Bool {
        !VeilCapabilityProvisioner.needsProvision(storedTicketB64: VeilTicketStore.ticket(for: address))
    }

    // MARK: - Entry points

    /// Opportunistic floor check — call alongside the capability pipeline (launch,
    /// foreground, confirmed VEIL-RPC success). Counts every capped front.
    func topUpIfBelowFloor(candidates: [String], through preferred: String?) {
        maybeTopUp(candidates: candidates, excluding: [], through: preferred)
    }

    /// A front just became unavailable (its native proxy failed to start/tunnel). It is
    /// excluded from the count so a capped-but-blocked front does not hide that we are now
    /// effectively down to one.
    func frontBecameUnavailable(_ address: String, candidates: [String], through preferred: String?) {
        maybeTopUp(candidates: candidates, excluding: [address], through: preferred)
    }

    // MARK: - Implementation

    private func maybeTopUp(candidates: [String], excluding: Set<String>, through preferred: String?) {
        guard !inFlight else { return }

        let usable = Self.usableCount(candidates: candidates, excluding: excluding, hasLiveCap: Self.hasLiveCap)
        // Below the floor, but at least one front we can still reach to carry the request.
        // usable == 0 means VEIL is already down — nothing to send the RPC through; the
        // cold floor (direct-path re-provision, or an out-of-band voucher) owns that.
        guard Self.isBelowFloor(usable), usable >= 1 else { return }

        if let last = lastAttempt, Date().timeIntervalSince(last) < retryInterval { return }

        // IssueVeilCapability is JWT-gated. Check before stamping `lastAttempt`, exactly as
        // the provisioner/renewer do — an attempt we know cannot succeed must not spend the
        // retry budget.
        guard KeychainManager.shared.loadSessionToken() != nil else {
            Log.debug("VEIL floor: top-up skipped — no session token yet", category: "VEIL")
            return
        }

        // Ask through a front that is actually usable: the preferred one if it qualifies,
        // else the first usable candidate. The RPC rides the live transport; `relayAddress`
        // only names the primary, and the value we want is the *alternates* it returns for
        // the other fronts (with N≥3 that includes one this device does not yet hold).
        let through = preferred.flatMap { usableReachable($0, excluding: excluding) }
            ?? candidates.first { usableReachable($0, excluding: excluding) != nil }
        guard let through else { return }

        inFlight = true
        lastAttempt = Date()
        Log.info("VEIL floor: \(usable)/\(Self.floor) usable front(s) — requesting top-up via \(through)", category: "VEIL")

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let issued = try await VeilServiceClient.shared.issueCapability(relayAddress: through)
                // We already hold `through`'s primary; the point of this call is the signed
                // alternates. They go through the same Option-C gate as every other path.
                let cached = VeilAlternatesCache.store(issued.alternates)
                Log.info("VEIL floor: cached \(cached)/\(issued.alternates.count) alternate front(s) via \(through)", category: "VEIL")
            } catch {
                Log.error("VEIL floor: top-up via \(through) failed: \(error)", category: "VEIL")
            }
        }
    }

    /// `address` if it is usable and not excluded, else nil.
    private func usableReachable(_ address: String, excluding: Set<String>) -> String? {
        guard !address.isEmpty, !excluding.contains(address), Self.hasLiveCap(address) else { return nil }
        return address
    }
}
