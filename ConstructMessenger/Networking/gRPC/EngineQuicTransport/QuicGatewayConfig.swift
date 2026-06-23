//
//  QuicGatewayConfig.swift
//  Construct Messenger
//
//  Single source of truth for the native quinn+h3 QUIC gateway coordinates
//  (`quic.konstruct.cc:443`), separate from the Envoy/Traefik H2 endpoint. Used by the
//  engine-QUIC channel config AND by veil-config import (to key the Salamander PSK by
//  gateway host — see QuicObfPskStore / decisions/salamander-psk-shared-per-gateway.md).
//

import Foundation

enum QuicGatewayConfig {
    /// TLS SNI / host of the QUIC gateway. Overridable via the `QUIC_GATEWAY_HOST` Info.plist key.
    static var host: String {
        Bundle.main.object(forInfoDictionaryKey: "QUIC_GATEWAY_HOST") as? String ?? "quic.konstruct.cc"
    }

    /// UDP port of the QUIC gateway. Overridable via the `QUIC_GATEWAY_PORT` Info.plist key.
    static var port: UInt16 {
        (Bundle.main.object(forInfoDictionaryKey: "QUIC_GATEWAY_PORT") as? String).flatMap(UInt16.init) ?? 443
    }
}
