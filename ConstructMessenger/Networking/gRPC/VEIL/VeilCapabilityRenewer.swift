//
//  VeilCapabilityRenewer.swift
//  Construct Messenger
//
//  In-band renewal of the stored veil-front capability (P4d). When a capability is
//  close to expiry, request a fresh one over the active transport (in-band over the
//  VEIL tunnel when it's up) and store it — so a tester's access never lapses and
//  they never have to re-import a QR/blob.
//
//  A pin is never taken from the response. The trust anchor — bundled pin, signed
//  manifest, or a front learned from a signature — is the source of truth, and
//  `TransportRouter` makes it win over anything pushed (anti-downgrade). The response
//  coordinates are put through `VeilRelayTrust.verify`, the same gate the primary and
//  alternates paths use; a disagreement is an operational signal that the relay's
//  certificate rotated, not something to adopt.
//

import Foundation

@MainActor
final class VeilCapabilityRenewer {
    static let shared = VeilCapabilityRenewer()
    private init() {}

    /// Renew once the stored capability has less than this remaining.
    private let renewWindow: TimeInterval = 14 * 24 * 3600   // 14 days
    /// Ceiling on how often to re-attempt within a session (avoids hammering on every
    /// VEIL RPC success). It is a ceiling, not the interval — see `retryInterval(…)`.
    private let maxRetryInterval: TimeInterval = 60 * 60      // 1 hour
    /// Floor, so a nearly-dead capability cannot turn into a retry loop.
    private let minRetryInterval: TimeInterval = 60           // 1 minute

    private var inFlight = false
    private var lastAttempt: Date?

    /// How long to wait before re-attempting, given what is left of the capability.
    ///
    /// A flat hour was wrong for the bootstrap voucher: `IssueBootstrapVoucher` mints a
    /// 45-minute B2 (`VOUCHER_TTL_SECS`), so one failed attempt consumed the *only*
    /// retry the capability would ever get, and it then expired — taking the transport
    /// with it, since the peer needs that transport to register and reach the backend at
    /// all. Pacing against the remaining lifetime keeps the hour for a 90-day capability
    /// and gives a 45-minute one several tries.
    nonisolated static func retryInterval(
        secondsLeft: TimeInterval, ceiling: TimeInterval, floor: TimeInterval
    ) -> TimeInterval {
        min(ceiling, max(floor, secondsLeft / 3))
    }

    /// Opportunistic check. Safe to call frequently (e.g. on every confirmed VEIL RPC
    /// success and at launch) — it no-ops unless the capability is near expiry and the
    /// retry interval has elapsed.
    func renewIfNeeded(relayAddress: String) {
        guard !inFlight else { return }

        guard let capB64 = VeilTicketStore.ticket(for: relayAddress),
              let parsed = try? VeilConfigImporter.parseCapability(capB64) else {
            return  // nothing stored, or unparseable — nothing to renew
        }
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        let secondsLeft = parsed.notAfter > now ? Double(parsed.notAfter - now) : 0
        guard secondsLeft < renewWindow else { return }   // not near expiry yet

        let interval = Self.retryInterval(
            secondsLeft: secondsLeft, ceiling: maxRetryInterval, floor: minRetryInterval
        )
        if let last = lastAttempt, Date().timeIntervalSince(last) < interval { return }

        // IssueVeilCapability is JWT-gated, and this fires on the first confirmed VEIL RPC
        // — which for a peer bootstrapped from a voucher happens *during* registration,
        // before there is a session. Checked BEFORE `lastAttempt` is stamped, exactly as
        // `VeilCapabilityProvisioner` does it: an attempt we know cannot succeed must not
        // consume the retry budget.
        guard KeychainManager.shared.loadSessionToken() != nil else {
            Log.debug("VEIL renew skipped — no session token yet", category: "VEIL")
            return
        }

        inFlight = true
        lastAttempt = Date()
        Log.info("VEIL renew: capability for \(relayAddress) expires in \(Int(secondsLeft))s — renewing in-band", category: "VEIL")

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let issued = try await VeilServiceClient.shared.issueCapability(relayAddress: relayAddress)
                let newB64 = issued.capability.base64EncodedString()

                // `issueCapability` prefers `response.relay_address` over the one we asked
                // for, and the server is the adversary here. Renewal is for one specific
                // relay — there is no legitimate reason for the answer to name a different
                // one, and taking it would silently stop renewing the relay we actually use
                // until its capability lapsed. Offering other fronts is what `alternates`
                // is for, and those go through the same gate below.
                guard issued.relayAddress == relayAddress else {
                    Log.error("VEIL renew: asked for \(relayAddress), answered \(issued.relayAddress) — refusing", category: "VEIL")
                    return
                }

                // The Option-C acceptance gate. This path used to skip it — it checked the
                // capability signature, stored the ticket, and only then compared the SPKI
                // as a log line. The primary and alternates paths were fixed; this one was
                // left behind, and a divergence nothing asserts is the kind that survives.
                if let rejection = VeilRelayTrust.verify(
                    relayAddress: issued.relayAddress,
                    spki: issued.spki,
                    capabilityB64: newB64,
                    capabilityVersion: issued.capabilityVersion
                ) {
                    switch rejection {
                    case .spkiMismatch:
                        // Actionable: the relay rotated its certificate. A bundled pin needs
                        // an app update; a learned front needs a fresh voucher. Either way the
                        // relay is already unreachable — `buildRelay` dials with our pin, not
                        // the response's — so storing the capability would help nothing.
                        Log.error("VEIL renew: \(issued.relayAddress) reports SPKI \(issued.spki.prefix(12))… — \(rejection.summary); relay cert rotated, ship an app update or re-voucher", category: "VEIL")
                    default:
                        Log.error("VEIL renew: refused renewed coordinates for \(issued.relayAddress) — \(rejection.summary)", category: "VEIL")
                    }
                    return
                }

                let newParsed = try VeilConfigImporter.parseCapability(newB64)

                guard VeilTicketStore.store(ticket: newB64, for: issued.relayAddress) else {
                    Log.error("VEIL renew: failed to store renewed capability for \(issued.relayAddress)", category: "VEIL")
                    return
                }
                Log.info("VEIL renew: capability renewed for \(issued.relayAddress) (new exp in \(Int((Double(newParsed.notAfter) - Date().timeIntervalSince1970) / 86400))d)", category: "VEIL")

                // EntryDirectory v1: cache the pre-issued alternate fronts so a blocked
                // primary can fail over without a round-trip. Validated against the signed
                // manifest inside VeilAlternatesCache (server-asserted coords aren't trusted).
                let cachedAlts = VeilAlternatesCache.store(issued.alternates)
                if cachedAlts > 0 {
                    Log.info("VEIL renew: cached \(cachedAlts)/\(issued.alternates.count) alternate front(s)", category: "VEIL")
                }
            } catch {
                Log.error("VEIL renew failed for \(relayAddress): \(error)", category: "VEIL")
            }
        }
    }
}
