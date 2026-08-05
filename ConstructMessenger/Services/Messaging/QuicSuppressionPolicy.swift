//
//  QuicSuppressionPolicy.swift
//  Construct Messenger
//
//  How long the fast-UDP transport (engine-QUIC / native H3) stays suppressed on a network
//  once we have concluded it does not work there, and what survives an app restart.
//
//  QUIC is the preferred transport wherever it is allowed: connection migration across
//  WiFi↔cellular and no head-of-line blocking. On networks that drop UDP/443 wholesale it is
//  not merely slower, it is a fixed tax — the handshake times out at ~3s before every H2
//  connect. Some networks (RU) block it permanently, so the tax was paid on every cold start.
//
//  The old policy could not converge on those networks:
//    · the failure counter lived only in memory, so every launch started from zero;
//    · the suppression window was a flat 300s, and expiring it *erased the record*, so the
//      device relearned "QUIC is blocked here" from scratch, forever, at 3s a time.
//
//  The ladder below fixes the second half; persisting `strikes` (see MessageStreamManager)
//  fixes the first. A network keeps its rung until it is a different network — the re-probe
//  trigger is a path change, not a timer. That is the user-visible contract: **we re-try QUIC
//  when you move, not when you relaunch.**
//
//  Deliberately NOT keyed on region/country: that needs a geo database in the bundle and would
//  be a worse predicate anyway — a VPN, a roaming SIM, or a hotel uplink makes the network's
//  behaviour disagree with the region it is nominally in. What we learn, we learn per network.
//

import Foundation

enum QuicSuppressionPolicy {

    /// Escalating suppression windows, indexed by how many times this network has already
    /// proved QUIC unusable. Short first (a transient UDP glitch must not cost a day of the
    /// better transport), then long enough that a permanently-blocked network is probed about
    /// once a day instead of once a launch.
    static let ladder: [TimeInterval] = [
        300,      // 5 min  — first conclusion, could still be a blip
        3_600,    // 1 h    — it held across a relaunch
        86_400    // 24 h   — treat as blocked; a path change still re-probes immediately
    ]

    /// Window for the suppression being armed now, given the strikes this network already carries.
    static func window(afterStrikes strikes: Int) -> TimeInterval {
        let index = max(0, min(strikes, ladder.count - 1))
        return ladder[index]
    }

    /// How many consecutive open failures we require before concluding the transport is unusable.
    ///
    /// Two on a network we know nothing about — a single timeout can be a lost packet, and
    /// giving up on QUIC costs the user a better transport. One on a network that has already
    /// taught us this: re-proving a known fact is what the 3s tax *is*.
    static func failuresBeforeSuppressing(strikes: Int) -> Int {
        strikes > 0 ? 1 : failuresOnUnknownNetwork
    }

    /// Was `MessageStreamManager.h3OpenFailureThreshold`; it lives here now so the count and the
    /// ladder it feeds cannot be tuned apart.
    static let failuresOnUnknownNetwork = 2

    /// What a persisted record means at launch.
    struct Restored: Equatable {
        /// Suppression still in force — go straight to H2 without probing.
        var suppressedUntil: Date?
        /// Rung this network sits on. Survives an expired window on purpose.
        var strikes: Int
    }

    /// An expired window is permission to probe again — **not** permission to forget.
    ///
    /// Erasing the strikes on expiry is what made the old policy unable to converge: every
    /// window that lapsed dropped the device back to rung zero, so a permanently blocked
    /// network was rediscovered at full price for the life of the install. Keeping the count
    /// means the next failure re-arms at the next rung instead of the first.
    ///
    /// A different network keeps nothing: what we learned is about that network, and interface
    /// identity is the only thing that makes the claim meaningful.
    static func restore(
        persistedUntil: Date?,
        persistedStrikes: Int,
        sameNetwork: Bool,
        now: Date = Date()
    ) -> Restored {
        guard sameNetwork else { return Restored(suppressedUntil: nil, strikes: 0) }
        let strikes = max(0, persistedStrikes)
        guard let until = persistedUntil, until > now else {
            return Restored(suppressedUntil: nil, strikes: strikes)
        }
        return Restored(suppressedUntil: until, strikes: strikes)
    }
}
