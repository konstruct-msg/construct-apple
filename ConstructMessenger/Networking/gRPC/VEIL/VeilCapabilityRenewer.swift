//
//  VeilCapabilityRenewer.swift
//  Construct Messenger
//
//  In-band renewal of the stored veil-front capability (P4d). When a capability is
//  close to expiry, request a fresh one over the active transport (in-band over the
//  VEIL tunnel when it's up) and store it — so a tester's access never lapses and
//  they never have to re-import a QR/blob.
//
//  Pin/SNI from the renewal response is deliberately NOT applied to a binary-pinned
//  relay: the hardcoded SPKI is the source of truth (TransportRouter makes it win
//  over any pushed pin — anti-downgrade). A drift between the response SPKI and the
//  binary pin is logged as an operational signal that the relay cert rotated and an
//  app update is needed. (For future non-pinned/community relays the pushed pin can
//  flow through the manifest cache; out of scope here.)
//

import Foundation

@MainActor
final class VeilCapabilityRenewer {
    static let shared = VeilCapabilityRenewer()
    private init() {}

    /// Renew once the stored capability has less than this remaining.
    private let renewWindow: TimeInterval = 14 * 24 * 3600   // 14 days
    /// Don't re-attempt more often than this within a session (avoids hammering on
    /// every VEIL RPC success).
    private let minRetryInterval: TimeInterval = 60 * 60      // 1 hour

    private var inFlight = false
    private var lastAttempt: Date?

    /// Opportunistic check. Safe to call frequently (e.g. on every confirmed VEIL RPC
    /// success and at launch) — it no-ops unless the capability is near expiry and the
    /// retry interval has elapsed.
    func renewIfNeeded(relayAddress: String) {
        guard !inFlight else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < minRetryInterval { return }

        guard let capB64 = VeilTicketStore.ticket(for: relayAddress),
              let parsed = try? VeilConfigImporter.parseCapability(capB64) else {
            return  // nothing stored, or unparseable — nothing to renew
        }
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        let secondsLeft = parsed.notAfter > now ? Double(parsed.notAfter - now) : 0
        guard secondsLeft < renewWindow else { return }   // not near expiry yet

        inFlight = true
        lastAttempt = Date()
        Log.info("VEIL renew: capability for \(relayAddress) expires in \(Int(secondsLeft / 86400))d — renewing in-band", category: "VEIL")

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let issued = try await VeilServiceClient.shared.issueCapability(relayAddress: relayAddress)
                let newB64 = issued.capability.base64EncodedString()

                // Validate the issuer signature + window client-side before trusting it.
                let newParsed = try VeilConfigImporter.parseCapability(newB64)

                guard VeilTicketStore.store(ticket: newB64, for: issued.relayAddress) else {
                    Log.error("VEIL renew: failed to store renewed capability for \(issued.relayAddress)", category: "VEIL")
                    return
                }
                Log.info("VEIL renew: capability renewed for \(issued.relayAddress) (new exp in \(Int((Double(newParsed.notAfter) - Date().timeIntervalSince1970) / 86400))d)", category: "VEIL")

                // Anti-downgrade: never override a binary-pinned relay's SPKI from the
                // response. Surface drift so we know a cert rotation needs an app update.
                if let pin = VEILConfig.hardcodedRelaySPKIs[issued.relayAddress],
                   !issued.spki.isEmpty, pin.lowercased() != issued.spki.lowercased() {
                    Log.error("VEIL renew: relay \(issued.relayAddress) reports SPKI \(issued.spki.prefix(12))… ≠ binary pin \(pin.prefix(12))… — relay cert rotated; ship an app update with the new pin", category: "VEIL")
                }
            } catch {
                Log.error("VEIL renew failed for \(relayAddress): \(error)", category: "VEIL")
            }
        }
    }
}
