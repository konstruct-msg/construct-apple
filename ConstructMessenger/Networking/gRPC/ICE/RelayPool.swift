//
//  RelayPool.swift
//  Construct Messenger
//
//  Relay selection and failure tracking for the new ConnectionLoop.
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
    private let relays: [IceRelay]

    /// Consecutive failure count per relay address. Resets to 0 on first success.
    private var failures: [String: Int] = [:]

    // MARK: - Init

    init(relays: [IceRelay]) {
        self.relays = relays
    }

    // MARK: - Selection

    /// Returns the relay with fewest consecutive failures.
    /// Returns nil only when the pool is empty.
    func best() -> IceRelay? {
        relays.min { failures[$0.address, default: 0] < failures[$1.address, default: 0] }
    }

    /// Returns the best relay excluding `address`, or falls back to `best()` if
    /// no alternatives exist (single-relay pool).
    func best(excluding address: String) -> IceRelay? {
        let alternatives = relays.filter { $0.address != address }
        return alternatives.min { failures[$0.address, default: 0] < failures[$1.address, default: 0] }
            ?? best()
    }

    // MARK: - Feedback

    mutating func recordSuccess(_ relay: IceRelay) {
        failures[relay.address] = 0
    }

    mutating func recordFailure(_ relay: IceRelay) {
        failures[relay.address, default: 0] += 1
    }

    /// Clears all failure counts. Called on network path change.
    mutating func resetFailures() {
        failures = [:]
    }

    // MARK: - Info

    var isEmpty: Bool { relays.isEmpty }
    var count: Int { relays.count }

    func failureCount(for relay: IceRelay) -> Int {
        failures[relay.address, default: 0]
    }
}
