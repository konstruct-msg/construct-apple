//
//  VeilAccessStatus.swift
//  Construct Messenger
//
//  Whether this device has veil-front access, without saying *where*.
//
//  The settings screen used to answer this by naming the relay — "Access configured for
//  <host>", selectable text. That was harmless only because the check was hardcoded to
//  the seed relay, whose address ships in the binary anyway. It stopped being harmless
//  the moment a front could arrive from a voucher: the whole point of a learned front is
//  that its coordinates exist nowhere public, and a settings screen is one screenshot
//  away from public. See construct-docs decisions/veil-front-coordinates-are-not-public.md.
//
//  So release builds get a boolean. Debug builds get the addresses — a build that never
//  leaves the operator's own devices is exactly where knowing which front you are on is
//  the difference between diagnosing a problem and guessing at it.
//

import Foundation

enum VeilAccessStatus {

    // MARK: - Pure core (unit-tested, no Keychain)

    /// The addresses among `candidates` that have some stored capability.
    ///
    /// Takes the lookup as a closure so the rule is testable on its own: "configured"
    /// means a capability exists for a relay we would actually dial — not that a
    /// particular hardcoded relay has one, which is what made a voucher-provisioned
    /// device report "no access configured" while it was connected through one.
    static func configured(
        candidates: [String],
        hasCapability: (String) -> Bool
    ) -> [String] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && hasCapability($0) }
    }

    // MARK: - Live

    /// True if any relay we would dial has a capability stored for it.
    ///
    /// Short-circuits rather than going through `configuredAddresses()`: this is a computed
    /// property read several times per SwiftUI body pass, and each candidate costs a
    /// Keychain query. The relay actually in use leads the candidate list, so this is
    /// normally one lookup.
    static var isConfigured: Bool {
        VeilRelaySelector.cachedRelayAddresses().contains(where: hasCapability)
    }

    /// Addresses with stored access. Debug-only in practice — release UI must ask
    /// `isConfigured` instead, which says whether without saying where.
    static func configuredAddresses() -> [String] {
        configured(candidates: VeilRelaySelector.cachedRelayAddresses(), hasCapability: hasCapability)
    }

    private static func hasCapability(_ address: String) -> Bool {
        VeilTicketStore.ticket(for: address) != nil
            || VeilCapabilityV2Store.capability(for: address) != nil
    }
}
