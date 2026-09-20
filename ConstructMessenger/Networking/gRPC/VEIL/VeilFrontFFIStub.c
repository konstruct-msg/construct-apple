// Weak stubs so the app links before construct-veil exports these symbols.
// A rebuilt xcframework with a strong definition wins.

#include <stdint.h>
#include <stddef.h>

__attribute__((weak))
int32_t veil_proxy_start_veil_front_external(int32_t relay_fd,
                                             const uint8_t *exporter, size_t exporter_len,
                                             const char *capability_v2_b64,
                                             const char *veil_sk_hex,
                                             const char *ticket_b64,
                                             uint16_t *port_out) {
    (void)relay_fd; (void)exporter; (void)exporter_len;
    (void)capability_v2_b64; (void)veil_sk_hex; (void)ticket_b64; (void)port_out;
    return -1;
}

__attribute__((weak))
int32_t veil_front_ferry_fd(int32_t local_fd,
                            int32_t relay_fd,
                            const uint8_t *exporter, size_t exporter_len,
                            const char *capability_v2_b64,
                            const char *veil_sk_hex,
                            const char *ticket_b64) {
    (void)local_fd; (void)relay_fd; (void)exporter; (void)exporter_len;
    (void)capability_v2_b64; (void)veil_sk_hex; (void)ticket_b64;
    return -1;
}
