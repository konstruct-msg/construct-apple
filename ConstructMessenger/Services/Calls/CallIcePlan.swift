//
//  CallIcePlan.swift
//  Construct Messenger
//
//  Which ICE servers a call uses. Every call goes through our TURN relay (owner, 2026-10-16, for
//  1.0): a direct call hands each side the other's network address, and an address names a person
//  where the account does not. Until then this held only with VEIL `on`, and the default (Auto)
//  allowed host and server-reflexive candidates.
//
//  - relay only (`iceTransportPolicy = .relay`): no host or server-reflexive candidates, so no
//    direct UDP to the peer and neither side learns the other's address;
//  - no fallback to STUN when TURN credentials could not be had: that fallback is a direct call.
//    The call fails instead, which the person can see; a leaked address they could not;
//  - with VEIL `on`, TURN over TLS (`turns:`) when the server offers it: the TURN handshake and the
//    media are inside TLS instead of in clear on 3478 (vault `security/konstrukt-unobservability-map.md`,
//    D8). Without VEIL plain TURN is kept for latency — UDP first.
//
//  What stays visible: a connection to the TURN host. Hiding that needs TURN behind a front.
//

import Foundation

struct CallIcePlan: Equatable {
    struct Server: Equatable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    /// One value since 2026-10-16; kept so the session applies what the plan says, and a test reads it.
    enum Policy: Equatable { case relay }

    let servers: [Server]
    let policy: Policy

    /// Nil when the call must not be placed: no TURN to relay through.
    static func make(turnURLs: [String]?, username: String, credential: String, veilOn: Bool) -> CallIcePlan? {
        let urls = turnURLs ?? []
        guard !urls.isEmpty else { return nil }
        let overTLS = urls.filter { $0.lowercased().hasPrefix("turns:") }
        let chosen = veilOn && !overTLS.isEmpty ? overTLS : urls
        return CallIcePlan(
            servers: [Server(urls: chosen, username: username, credential: credential)],
            policy: .relay
        )
    }
}
