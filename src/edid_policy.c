#include "edid_policy.h"
#include <string.h>

static const uint8_t ep_header[] = {0,255,255,255,255,255,255,0};

bool ep_block_valid(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 128) return false;
    unsigned sum = 0;
    for (size_t i=0; i<128; ++i) sum += bytes[i];
    return (sum & 255u) == 0;
}

static bool prefix_valid(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 128 || length > EP_MAX_EDID_BYTES || length % 128 ||
        memcmp(bytes, ep_header, sizeof(ep_header)) || bytes[18] != 1) return false;
    if (length / 128 > (size_t)bytes[126]+1) return false;
    for (size_t off=0; off<length; off+=128)
        if (!ep_block_valid(bytes+off, length-off)) return false;
    return true;
}

bool ep_edid_valid(const uint8_t *bytes, size_t length) {
    return prefix_valid(bytes, length) && length / 128 == (size_t)bytes[126]+1;
}

static bool read_serial(const uint8_t *d, char out[EP_SERIAL_BYTES]) {
    if (d[0] || d[1] || d[2] || d[3] != 0xff || d[4]) return false;
    char text[EP_SERIAL_BYTES] = {0};
    size_t n=0;
    bool meaningful=false;
    while (n<13 && d[5+n] && d[5+n]!=0x0a) {
        uint8_t c=d[5+n];
        if (c<0x20 || c>0x7e) return false;
        text[n++]=(char)c;
        if (c!='0' && c!=' ') meaningful=true;
    }
    while (n && text[n-1]==' ') --n;
    text[n]=0;
    if (!n || !meaningful || !strcmp(text,"UNKNOWN") || !strcmp(text,"Unknown") ||
        !strcmp(text,"N/A") || !strcmp(text,"n/a")) return false;
    memcpy(out,text,sizeof(text));
    return true;
}

bool ep_identity(const uint8_t *bytes, size_t length, bool prefix, EPIdentity *out) {
    if (!out) return false;
    memset(out,0,sizeof(*out));
    if (!(prefix ? prefix_valid(bytes,length) : ep_edid_valid(bytes,length))) return false;
    out->vendor=(uint16_t)(((uint16_t)bytes[8]<<8)|bytes[9]);
    out->product=(uint16_t)(bytes[10]|((uint16_t)bytes[11]<<8));
    out->numeric_serial=bytes[12]|((uint32_t)bytes[13]<<8)|
        ((uint32_t)bytes[14]<<16)|((uint32_t)bytes[15]<<24);
    out->has_numeric=out->numeric_serial!=0 && out->numeric_serial!=UINT32_MAX;
    out->verified=true;
    for (size_t off=54; off+18<=127; off+=18) {
        if (read_serial(bytes+off,out->text_serial)) { out->has_text=true; break; }
    }
    if (!out->has_text && length>=256 && bytes[128]==2) {
        const uint8_t *cta=bytes+128;
        size_t start=cta[2];
        if (start==0) return true; // No CTA detailed descriptors.
        if (start<4 || start>127) { memset(out,0,sizeof(*out)); return false; }
        for (size_t off=4; off<start;) {
            size_t next=off+1+(cta[off]&31u);
            if (next>start) { memset(out,0,sizeof(*out)); return false; }
            off=next;
        }
        for (size_t off=start; off+18<=127; off+=18) {
            if (read_serial(cta+off,out->text_serial)) { out->has_text=true; break; }
        }
    }
    return true;
}

bool ep_identity_usable(const EPIdentity *identity) {
    return identity && identity->verified && identity->vendor &&
        (identity->has_numeric || identity->has_text);
}

bool ep_matches(const EPIdentity *expected, const EPIdentity *physical) {
    if (!ep_identity_usable(expected) || !physical || !physical->verified ||
        expected->vendor!=physical->vendor || expected->product!=physical->product) return false;
    if (expected->has_numeric && (!physical->has_numeric ||
        expected->numeric_serial!=physical->numeric_serial)) return false;
    if (expected->has_text && (!physical->has_text ||
        strcmp(expected->text_serial,physical->text_serial))) return false;
    return true;
}

bool ep_identity_equal(const EPIdentity *a, const EPIdentity *b) {
    return a && b && a->verified && b->verified && a->vendor==b->vendor &&
        a->product==b->product && a->has_numeric==b->has_numeric && a->has_text==b->has_text &&
        (!a->has_numeric || a->numeric_serial==b->numeric_serial) &&
        (!a->has_text || !strcmp(a->text_serial,b->text_serial));
}

bool ep_profile_edids_compatible(const uint8_t *factory, size_t factory_len,
                                const uint8_t *override, size_t override_len) {
    EPIdentity a,b;
    return ep_identity(factory,factory_len,false,&a) && ep_identity_usable(&a) &&
        ep_identity(override,override_len,false,&b) && ep_identity_equal(&a,&b);
}

bool ep_plan(const EPProfile *profiles, size_t profile_count,
             const EPIdentity *displays, size_t display_count, int *plan) {
    if (profile_count>EP_MAX_PROFILES || display_count>EP_MAX_DISPLAYS ||
        (profile_count && !profiles) || (display_count && (!displays || !plan))) return false;
    unsigned per_profile[EP_MAX_PROFILES]={0};
    for (size_t d=0; d<display_count; ++d) {
        int candidate=EP_NONE;
        unsigned count=0;
        for (size_t p=0; p<profile_count; ++p) {
            if (profiles[p].enabled && ep_matches(&profiles[p].identity,&displays[d])) {
                ++count; ++per_profile[p]; candidate=(int)p;
            }
        }
        plan[d]=count>1 ? EP_AMBIGUOUS : candidate;
    }
    for (size_t d=0; d<display_count; ++d)
        if (plan[d]>=0 && per_profile[plan[d]]!=1) plan[d]=EP_AMBIGUOUS;
    return true;
}
