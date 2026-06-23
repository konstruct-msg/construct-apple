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

    /// **Temporary dev embedding.** The shared per-gateway Salamander PSK, hard-coded in the app
    /// until in-band provisioning + UI delivery exist (Phase B; see
    /// decisions/salamander-psk-shared-per-gateway.md). Must equal the gateway's `QUIC_OBF_PSK`.
    /// A PSK provisioned into `QuicObfPskStore` always takes precedence over this fallback.
    /// This being in the binary is acceptable: the PSK is an obfuscation / probing-resistance
    /// secret, not an authentication key (QUIC TLS + JWT + capability + E2EE provide those).
    private static let bundledObfPskHex =
        "f64f3850b455ed478c1ed654f202d455904259d8a7b513539372541c4dc43c44"

    /// The bundled PSK decoded to bytes (nil only if the hex constant is malformed).
    static var bundledObfPsk: Data? {
        let hex = bundledObfPskHex
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}
