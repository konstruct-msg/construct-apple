//
//  RelayPool.swift
//  Construct Messenger
//
//  Relay selection and failure tracking for the transport router.
//
//  Replaces the blacklist TTL / cooldown / quality-score system with a simple
//  consecutive-failure counter per relay. `best()` always returns a relay —
//  the one with fewest failures — so the connection loop never stalls waiting
//  for a blacklist to expire.
//

import Foundation

struct RelayPool {

    // MARK: - State

    /// Relays ordered by TCP latency (fastest first). Set once at init.
    private let relays: [VeilRelay]

    /// Consecutive failure count per relay address. Resets to 0 on `recordSuccess` or `resetFailures`.
    private var failures: [String: Int] = [:]

    /// Persistent deprioritisation weight for relays whose WebTunnel endpoint is carrier-blocked
    /// (HTTP 404 response). Survives `resetFailures()` because WebTunnel blocking is a network-level
    /// policy that doesn't clear on a simple path change. Cleared on `recordSuccess`.
    private var webTunnelBlockedPenalty: [String: Int] = [:]

    /// Weight added each time a relay's WebTunnel endpoint returns a 404. Capped at `maxBlockedPenalty`.
    private static let blockedPenaltyStep = 5
    private static let maxBlockedPenalty  = 50

    // MARK: - Init

    init(relays: [VeilRelay], blockedPenalty: [String: Int] = [:], failures: [String: Int] = [:]) {
        self.relays = relays
        self.webTunnelBlockedPenalty = blockedPenalty
        let present = Set(relays.map(\.address))
        self.failures = failures.filter { present.contains($0.key) }
    }

    // MARK: - Selection

    private func effectiveScore(for address: String) -> Int {
        failures[address, default: 0] + webTunnelBlockedPenalty[address, default: 0]
    }

    /// Returns the relay with fewest effective failures (transient + persistent penalty).
    /// Returns nil only when the pool is empty.
    func best() -> VeilRelay? {
        relays.min { effectiveScore(for: $0.address) < effectiveScore(for: $1.address) }
    }

    /// Returns the best relay excluding `address`, or falls back to `best()` if
    /// no alternatives exist (single-relay pool).
    func best(excluding address: String) -> VeilRelay? {
        let alternatives = relays.filter { $0.address != address }
        return alternatives.min { effectiveScore(for: $0.address) < effectiveScore(for: $1.address) }
            ?? best()
    }

    /// The best relay not in `tried`, or nil once every one is. Not `best()` in a loop that stops
    /// at the first repeat: after a failure two fronts can tie, `best()` answers the one already
    /// tried, and the untried one behind it was never dialled.
    func best(notIn tried: Set<String>) -> VeilRelay? {
        relays.filter { !tried.contains($0.address) }
            .min { effectiveScore(for: $0.address) < effectiveScore(for: $1.address) }
    }

    // MARK: - Feedback

    mutating func recordSuccess(_ relay: VeilRelay) {
        failures[relay.address] = 0
        webTunnelBlockedPenalty[relay.address] = 0
    }

    mutating func recordSuccess(address: String) {
        failures[address] = 0
        webTunnelBlockedPenalty[address] = 0
    }

    mutating func recordFailure(_ relay: VeilRelay) {
        failures[relay.address, default: 0] += 1
    }

    mutating func recordFailure(address: String) {
        failures[address, default: 0] += 1
    }

    /// Records a carrier-level WebTunnel block. The penalty accumulates across `resetFailures()`
    /// calls so a reset to a new network path doesn't immediately retry a known-blocked relay.
    mutating func recordWebTunnelBlocked(_ relay: VeilRelay) {
        let current = webTunnelBlockedPenalty[relay.address, default: 0]
        webTunnelBlockedPenalty[relay.address] = min(current + Self.blockedPenaltyStep, Self.maxBlockedPenalty)
    }

    /// Clears transient failure counts. Called on network path change.
    /// Does NOT clear `webTunnelBlockedPenalty` — carrier-level WebTunnel blocks persist.
    mutating func resetFailures() {
        failures = [:]
    }

    // MARK: - Info

    var isEmpty: Bool { relays.isEmpty }
    var count: Int { relays.count }

    /// Consecutive failures per relay — carried into a rebuilt pool (`NativeProxyEffector.updateRelays`).
    var failureCounts: [String: Int] { failures }

    /// Current WebTunnel block penalties — read by the router to persist across launches.
    var blockedPenalty: [String: Int] { webTunnelBlockedPenalty }

    func failureCount(for relay: VeilRelay) -> Int {
        failures[relay.address, default: 0]
    }

    func failureCount(for address: String) -> Int {
        failures[address, default: 0]
    }
}
