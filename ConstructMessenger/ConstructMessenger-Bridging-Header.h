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
#import "construct_transportFFI.h"

// VEIL (construct-veil). Declared here: only what Swift calls — veil_start, veil_stop,
// veil_last_error, veil_front_ferry_fd. The functions are compiled into libconstruct_core.a;
// their definitions and contracts are in construct-veil src/ffi.rs.
//
// Method ID legend in VeilStartResult.method: 0=obfs4, 1=webtunnel, 2=masque,
// 3=veil-front (honest-front HTTPS).
#include <stdint.h>
#include <stddef.h>

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
    // fast). Superseded (not replaced) by veil_capability_v2_b64 below (ticket B1).
    const char *veil_front_ticket_b64;
    // Base64-encoded key-bound CapabilityV2 blob (ticket B1, AUTH v3). NULL/empty
    // falls back to veil_front_ticket_b64 (AUTH v2). Must be paired with
    // veil_sk_hex below.
    const char *veil_capability_v2_b64;
    // Hex-encoded 32-byte Ed25519 veil_sk seed — generated and stored locally
    // (Keychain). Never derived from or sent to the relay. NULL/empty = AUTH v3
    // not configured.
    const char *veil_sk_hex;
    // 32-byte device key (Keychain) that keys the scores fingerprint hash
    // (HMAC-SHA256). NULL / scoring_key_len != 32 = no key (bare SHA-256, which is
    // only acceptable for the in-memory path). MUST be the last fields — Rust
    // struct layout depends on them.
    const uint8_t *scoring_key;
    size_t scoring_key_len;
} VeilStartRequest;

typedef struct VeilStartResult {
    uint16_t port;
    uint8_t  method;
    uint32_t latency_ms;
} VeilStartResult;

int32_t  veil_start(VeilStartRequest req, VeilStartResult *out);
int32_t  veil_stop(void);

// Copy the most recent veil_start failure reason into buf (NUL-terminated,
// truncated to cap). Returns the full reason length excluding NUL. Call after
// veil_start returns -1 to log the exact failing method + stage.
size_t   veil_last_error(char *buf, size_t cap);

// Ferry ONE host-terminated veil-front connection over an already-accepted local
// socket (variant A, persistent-listener form). The host owns the stable local
// gRPC listener and accepts connections; per accept it dials a fresh native
// NWConnection and calls this once with:
//
//   local_fd:          the accepted local gRPC TCP socket. Rust adopts + closes it.
//   relay_fd:          one end of a socketpair carrying the DECRYPTED relay duplex
//                      for that NWConnection; the host pumps the other end. Rust
//                      adopts + closes it.
//   exporter/len:      32-byte sec_protocol_metadata_create_secret over
//                      EXPORTER_LABEL ("construct veil-front auth v1"), for THAT
//                      NWConnection.
//   capability_v2_b64
//   + veil_sk_hex:     AUTH v3 material; empty veil_sk_hex falls back to AUTH v2
//                      with ticket_b64.
//
// Both fds are adopted unconditionally (closed by Rust on every path). Spawns the
// ferry and returns immediately: 0 if started, -1 on bad arguments. The ferry ends
// when either side closes; the host sees EOF on its socketpair end. Keeping the
// local listener host-side lets the port outlive any single gRPC connection, which
// removes the one-shot-listener reconnect flap. See construct-veil src/ffi.rs.
int32_t veil_front_ferry_fd(int32_t local_fd,
                            int32_t relay_fd,
                            const uint8_t *exporter, size_t exporter_len,
                            const char *capability_v2_b64,
                            const char *veil_sk_hex,
                            const char *ticket_b64);

#endif /* ConstructMessenger_Bridging_Header_h */
