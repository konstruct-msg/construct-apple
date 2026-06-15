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

// VEIL (construct-veil) — obfs4 traffic obfuscation proxy
// Symbols are compiled into libconstruct_core.a
#include <stdint.h>
#include <stddef.h>
int32_t veil_proxy_start(const char *bridge_line, const char *relay_addr, uint16_t *port_out);
int32_t veil_proxy_start_tls(const char *bridge_line, const char *relay_addr,
                            const char *tls_server_name, uint16_t *port_out);
/// TLS proxy with SPKI cert pinning + fake/empty SNI (DPI evasion).
/// tls_sni: SNI for ClientHello — empty string = no SNI (IP-mode, no domain leaked).
///          Set to e.g. "storage.yandexcloud.net" for REALITY-style fake SNI.
/// spki_hex: lowercase hex SHA-256 of DER SubjectPublicKeyInfo — empty = no pinning.
int32_t veil_proxy_start_tls_pinned(const char *bridge_line, const char *relay_addr,
                                   const char *tls_sni, const char *spki_hex,
                                   uint16_t *port_out);
/// TLS proxy with SPKI pinning + browser TLS fingerprint profile (DPI evasion).
/// tls_profile: "chrome131" (Chrome 131), "firefox128" (Firefox 128), or "" (rustls defaults).
/// Use "chrome131" to disguise TLS ClientHello as Chrome traffic and evade fingerprint-based DPI.
int32_t veil_proxy_start_tls_profiled(const char *bridge_line, const char *relay_addr,
                                     const char *tls_sni, const char *spki_hex,
                                     const char *tls_profile, uint16_t *port_out);
int32_t veil_proxy_stop(void);
int32_t veil_proxy_is_running(void);
uint16_t veil_proxy_port(void);
/// TLS proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t veil_proxy_port_tls(void);
/// Plain obfs4 proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t veil_proxy_port_plain(void);

/// WebTunnel (WebSocket-over-TLS) proxy for DPI evasion (construct-ice v2).
///
/// Traffic appears as standard wss:// connections to bypass DPI.
/// The auth token is derived per-connection from bridge_cert and the current
/// time period (SHA-256(bridge_cert || "webtunnel-v1" || period_u64_be)[:8]).
///
/// relay_addr:   IP:port of the relay ("158.160.140.67:443").
/// tls_sni:      TLS SNI — set to CDN domain for fronting, or empty for IP-mode.
/// spki_hex:     lowercase hex SHA-256 of relay DER SPKI — empty = no pinning.
/// host_header:  HTTP Host header for WebSocket upgrade (for domain fronting).
/// bridge_cert:  base64-encoded obfs4 bridge cert from relay manifest.
/// wt_base_path: WebSocket resource base path (e.g. "/api/stream"), without token.
/// port_out:     local TCP port the proxy listens on.
int32_t veil_proxy_start_webtunnel(const char *relay_addr,
                                   const char *tls_sni, const char *spki_hex,
                                   const char *host_header, const char *bridge_cert,
                                   const char *wt_base_path, uint16_t *port_out);
/// WebTunnel proxy port (0 = not running).
uint16_t veil_proxy_port_webtunnel(void);

// ── VEIL Coordinator FFI (Phase 1+) ─────────────────────────────────────────
//
// FSM-based unified entry point with parallel happy-eyeballs probing of
// obfs4 and WebTunnel. Replaces the per-method veil_proxy_start_* family.
// Gated by `coordinator` feature in construct-veil; symbols are present when
// libconstruct_core.a is built with construct-veil?/coordinator enabled.
//
// Method ID legend in VeilStartResult.method: 0=obfs4, 1=webtunnel, 2=masque,
// 3=veil-front (honest-front HTTPS).

typedef struct VeilStartRequest {
    const char *relay_addr;            // "host:port"
    const char *bundle;                // "cert=<base64> iat-mode=<n>"
    const char *tls_sni;               // SNI ("" = none)
    const char *spki_hex;              // SPKI hex pin ("" = none)
    const char *host_header;           // WebTunnel HTTP Host header
    const char *wt_base_path;          // WebTunnel WS base path
    const uint8_t *network_fingerprint;// Caller-provided scoring key bytes
    size_t network_fingerprint_len;
    uint32_t allowed_methods;          // bitmask, 0 = all
    const char *scores_path;           // SQLite path, NULL = in-memory
    // Base64-encoded veil-front ticket (65 raw bytes pre-encoding). Empty / NULL
    // excludes veil-front from the probe race (its ticket parse fails the probe
    // fast). MUST be the last field — Rust struct layout depends on it.
    const char *veil_front_ticket_b64;
} VeilStartRequest;

typedef struct VeilStartResult {
    uint16_t port;
    uint8_t  method;
    uint32_t latency_ms;
} VeilStartResult;

int32_t  veil_start(VeilStartRequest req, VeilStartResult *out);
int32_t  veil_stop(void);
int32_t  veil_is_alive(void);
uint16_t veil_port(void);

// Copy the most recent veil_start failure reason into buf (NUL-terminated,
// truncated to cap). Returns the full reason length excluding NUL. Call after
// veil_start returns -1 to log the exact failing method + stage.
size_t   veil_last_error(char *buf, size_t cap);

#endif /* ConstructMessenger_Bridging_Header_h */
