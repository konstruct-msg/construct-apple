//
//  CallIcePlan.swift
//  Construct Messenger
//
//  Which ICE servers a call uses, and whether it may go direct.
//
//  With VEIL `on` the person asked that nothing of theirs be seen on the network. A call cannot go
//  through the tunnel today, so the plan keeps it as quiet as it can be outside it (vault
//  `security/konstrukt-unobservability-map.md`, D8):
//
//  - relay only (`iceTransportPolicy = .relay`): no host or server-reflexive candidates, so no
//    direct UDP to the peer and neither side learns the other's address;
//  - TURN over TLS (`turns:`) when the server offers it: the TURN handshake, the username among it,
//    and the media are inside TLS instead of in clear on 3478;
//  - no fallback to plain STUN when TURN credentials could not be had: that fallback is a direct
//    call. The call fails instead, which the person can see; a direct call they could not.
//
//  What stays visible: a TLS connection to the TURN host. Hiding that needs TURN behind a front.
//

import Foundation

struct CallIcePlan: Equatable {
    struct Server: Equatable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    enum Policy: Equatable { case all, relay }

    let servers: [Server]
    let policy: Policy

    /// Own STUN server, the fallback when no TURN credentials came. Never a public one: call
    /// metadata must not reach Google or Cloudflare.
    static let ownStunFallback = "stun:ams.konstruct.cc:3478"

    /// Nil when the call must not be placed: VEIL `on` and no TURN to relay through.
    static func make(turnURLs: [String]?, username: String, credential: String, veilOn: Bool) -> CallIcePlan? {
        let urls = turnURLs ?? []
        guard veilOn else {
            guard !urls.isEmpty else {
                return CallIcePlan(servers: [Server(urls: [ownStunFallback], username: nil, credential: nil)], policy: .all)
            }
            return CallIcePlan(servers: [Server(urls: urls, username: username, credential: credential)], policy: .all)
        }
        guard !urls.isEmpty else { return nil }
        let overTLS = urls.filter { $0.lowercased().hasPrefix("turns:") }
        return CallIcePlan(
            servers: [Server(urls: overTLS.isEmpty ? urls : overTLS, username: username, credential: credential)],
            policy: .relay
        )
    }
}
