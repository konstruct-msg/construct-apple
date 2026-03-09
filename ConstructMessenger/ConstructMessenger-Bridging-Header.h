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
int32_t ice_proxy_stop(void);
int32_t ice_proxy_is_running(void);
uint16_t ice_proxy_port(void);

#endif /* ConstructMessenger_Bridging_Header_h */
