//
//  RouteWait.swift
//  Construct Messenger
//
//  What an outgoing send does while VEIL is `on` and no tunnel is up (todo 320).
//

import Foundation

/// One waiter per peer for the queue's drain while there is no route.
///
/// Field export, build 782, 2026-11-19: a network change took the tunnel down for ~50 s, and four
/// triggers (reachability, connection status, session ready, the stuck-send check) each ran the
/// queue — 12 drains in ~35 s, every one turning the rows back to "sending" and failing at once on
/// `VeilTunnelNotUp`. The person saw the bubble flicker and tapped retry five times. Nothing could
/// be sent until the tunnel came back, and the triggers knew that before they started.
///
/// A drain with no route now waits instead: the first trigger for a peer starts one wait for the
/// route, every later one joins it, and the rows stay `.queued` — which is what they are.
struct RouteWaitGate {
    enum Admission: Equatable {
        /// A route exists: send now.
        case now
        /// No route, and nobody waits for this peer yet: start the one wait.
        case startWaiting
        /// No route, and a wait for this peer is already running: it will drain this too.
        case joinWaiting

        /// Only a route sends; both waits leave the rows for the drain the wait runs.
        var sendsNow: Bool { self == .now }
    }

    private var waiting: Set<String> = []

    mutating func admit(_ peer: String, routed: Bool) -> Admission {
        if routed { return .now }
        return waiting.insert(peer).inserted ? .startWaiting : .joinWaiting
    }

    /// The wait for [peer] ended — the route came back, or the wait gave up. The next trigger
    /// decides afresh.
    mutating func finished(_ peer: String) {
        waiting.remove(peer)
    }

    var isEmpty: Bool { waiting.isEmpty }
}

/// A reaction or an edit has no row in the queue, so a failure on the way out reached the person
/// as "couldn't send" while the message sent in the same second waited and went (build 782:
/// three reactions and one edit, all `VeilTunnelNotUp`). It now waits for the route, as a media
/// upload does, and one transport failure gets one more try once the route is back.
///
/// Sending it twice is harmless: a reaction names its target and its emoji, an edit its target and
/// its text, so a copy that did arrive the first time is applied again with the same result.
enum ActionSend {
    /// Runs on the caller's actor (`isolation`), so the closures never cross one.
    static func whenRouted<T>(
        isolation: isolated (any Actor)? = #isolation,
        waitForRoute: () async -> Bool,
        isRetryable: (Error) -> Bool,
        _ send: () async throws -> T
    ) async throws -> T {
        // A route that never came (the wait's own limit) is not waited for a second time.
        let routed = await waitForRoute()
        do {
            return try await send()
        } catch {
            guard routed, isRetryable(error), await waitForRoute() else { throw error }
            return try await send()
        }
    }
}
