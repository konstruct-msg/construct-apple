//
//  ConstructMessenger-Bridging-Header.h
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 22.12.2025.
//  Updated for UniFFI on 26.12.2025
//
#ifndef ConstructMessenger_Bridging_Header_h
#define ConstructMessenger_Bridging_Header_h

// UniFFI generated C header (provides FFI functions for Rust integration)
#import "construct_coreFFI.h"

// ICE (construct-ice) — obfs4 traffic obfuscation proxy
// Symbols are compiled into libconstruct_core.a
#include <stdint.h>
int32_t ice_proxy_start(const char *bridge_line, const char *relay_addr, uint16_t *port_out);
int32_t ice_proxy_start_tls(const char *bridge_line, const char *relay_addr,
                            const char *tls_server_name, uint16_t *port_out);
/// TLS proxy with SPKI cert pinning + fake/empty SNI (DPI evasion).
/// tls_sni: SNI for ClientHello — empty string = no SNI (IP-mode, no domain leaked).
///          Set to e.g. "storage.yandexcloud.net" for REALITY-style fake SNI.
/// spki_hex: lowercase hex SHA-256 of DER SubjectPublicKeyInfo — empty = no pinning.
int32_t ice_proxy_start_tls_pinned(const char *bridge_line, const char *relay_addr,
                                   const char *tls_sni, const char *spki_hex,
                                   uint16_t *port_out);
/// TLS proxy with SPKI pinning + browser TLS fingerprint profile (DPI evasion).
/// tls_profile: "chrome131" (Chrome 131), "firefox128" (Firefox 128), or "" (rustls defaults).
/// Use "chrome131" to disguise TLS ClientHello as Chrome traffic and evade fingerprint-based DPI.
int32_t ice_proxy_start_tls_profiled(const char *bridge_line, const char *relay_addr,
                                     const char *tls_sni, const char *spki_hex,
                                     const char *tls_profile, uint16_t *port_out);
int32_t ice_proxy_stop(void);
int32_t ice_proxy_is_running(void);
uint16_t ice_proxy_port(void);
/// TLS proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t ice_proxy_port_tls(void);
/// Plain obfs4 proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t ice_proxy_port_plain(void);

/// WebTunnel (WebSocket-over-TLS) proxy for DPI evasion (construct-ice v2).
///
/// Traffic appears as standard wss:// connections to bypass DPI.
///
/// relay_addr:  IP:port of the relay ("158.160.140.67:443").
/// tls_sni:     TLS SNI — set to CDN domain for fronting, or empty for IP-mode.
/// spki_hex:    lowercase hex SHA-256 of relay DER SPKI — empty = no pinning.
/// host_header: HTTP Host header for WebSocket upgrade (for domain fronting).
/// path:        WebSocket resource path (e.g. "/construct-ice"). Empty → "/".
/// port_out:    local TCP port the proxy listens on.
int32_t ice_proxy_start_webtunnel(const char *relay_addr,
                                   const char *tls_sni, const char *spki_hex,
                                   const char *host_header, const char *path,
                                   uint16_t *port_out);
/// WebTunnel proxy port (0 = not running).
uint16_t ice_proxy_port_webtunnel(void);

#endif /* ConstructMessenger_Bridging_Header_h */
