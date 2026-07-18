//
//  DiscoveredRelayStore.swift
//  Construct Messenger
//
//  Nonisolated, thread-safe snapshot of the trust-gated relays learned via
//  EntryDirectory Source 3 (`VeilLocalDiscovery`, mDNS/LAN).
//
//  Why a separate store: `VeilLocalDiscovery` is `@MainActor` (it drives an
//  `NWBrowser` and owns UI-adjacent state), but the relay-build path that must
//  consume its output — `VeilRelaySelector.cachedRelayAddresses()` and
//  `ConnectionLoopRelayBridge.buildRelay(address:)` — is nonisolated and
//  synchronous (called from `makeRelay`-style non-async contexts). This store is
//  the hand-off: the MainActor discovery *publishes* a snapshot here, and the
//  sync resolvers *read* it from any thread under a lock.
//
//  Trust note: entries land here ONLY after `VeilLocalDiscovery` has already
//  matched their advertised SPKI against a trusted identity (seed pin ∪ signed
//  manifest). The store carries the trust-gated `spki`, and the relay build path
//  applies it as an unconditional TLS pin — so nothing in this store can widen
//  trust; it only records reachability for identities we already trust.
//

import Foundation

/// Thread-safe snapshot of discovered (already trust-gated) island relays.
final class DiscoveredRelayStore: @unchecked Sendable {
    static let shared = DiscoveredRelayStore()

    private let lock = NSLock()
    private var byAddress: [String: DiscoveredRelay] = [:]

    private init() {}

    /// Replace the full snapshot. Called by `VeilLocalDiscovery` on the main actor
    /// whenever its discovered set changes.
    func publish(_ relays: [DiscoveredRelay]) {
        lock.withLock {
            byAddress = Dictionary(relays.map { ($0.addressWithPort, $0) },
                                   uniquingKeysWith: { first, _ in first })
        }
    }

    /// Drop all discovered entries (they are only valid on the current LAN).
    func clear() {
        lock.withLock { byAddress.removeAll() }
    }

    /// The trust-gated relay for `address`, or nil if not discovered.
    func relay(for address: String) -> DiscoveredRelay? {
        lock.withLock { byAddress[address] }
    }

    /// All discovered `host:port` addresses (unordered).
    func addresses() -> [String] {
        lock.withLock { Array(byAddress.keys) }
    }

    /// All discovered relays (unordered).
    func all() -> [DiscoveredRelay] {
        lock.withLock { Array(byAddress.values) }
    }
}
