#ifndef EDID_POLICY_H
#define EDID_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define EP_MAX_EDID_BYTES 4096u
#define EP_MAX_PROFILES 64u
#define EP_MAX_DISPLAYS 64u
#define EP_SERIAL_BYTES 14u
#define EP_NONE (-1)
#define EP_AMBIGUOUS (-2)

typedef struct {
    uint16_t vendor;
    uint16_t product;
    uint32_t numeric_serial;
    char text_serial[EP_SERIAL_BYTES];
    bool has_numeric;
    bool has_text;
    bool verified;
} EPIdentity;

typedef struct {
    EPIdentity identity;
    bool enabled;
} EPProfile;

bool ep_edid_valid(const uint8_t *bytes, size_t length);
bool ep_block_valid(const uint8_t *bytes, size_t length);
/* Prefix mode validates every supplied block, but permits omitted extensions.
 * Identity is deliberately taken only from base + first CTA extension, which
 * can be read at EDID address 0x50 without changing the E-DDC segment pointer. */
bool ep_identity(const uint8_t *bytes, size_t length, bool prefix, EPIdentity *out);
bool ep_identity_usable(const EPIdentity *identity);
bool ep_matches(const EPIdentity *expected, const EPIdentity *physical);
bool ep_identity_equal(const EPIdentity *a, const EPIdentity *b);
bool ep_profile_edids_compatible(const uint8_t *factory, size_t factory_len,
                                const uint8_t *override, size_t override_len);
/* Build the complete plan before applying anything. A profile needs exactly
 * one physical match, and a display needs exactly one enabled profile. */
bool ep_plan(const EPProfile *profiles, size_t profile_count,
             const EPIdentity *displays, size_t display_count, int *plan);
#endif
