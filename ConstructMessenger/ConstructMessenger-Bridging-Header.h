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
int32_t ice_proxy_stop(void);
int32_t ice_proxy_is_running(void);
uint16_t ice_proxy_port(void);
/// TLS proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t ice_proxy_port_tls(void);
/// Plain obfs4 proxy port specifically (dual-proxy happy-eyeballs mode).
uint16_t ice_proxy_port_plain(void);

#endif /* ConstructMessenger_Bridging_Header_h */
